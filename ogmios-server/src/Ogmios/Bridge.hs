--  This Source Code Form is subject to the terms of the Mozilla Public
--  License, v. 2.0. If a copy of the MPL was not distributed with this
--  file, You can obtain one at http://mozilla.org/MPL/2.0/.

{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}

{-# OPTIONS_GHC -fno-warn-unticked-promoted-constructors #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

module Ogmios.Bridge
    (
    -- * Clients
      pipeClients
    , handleIOException

    -- * Internals
    , FindIntersect (..)
    , FindIntersectResponse (..)
    , RequestNext (..)
    , RequestNextResponse (..)

    , SubmitTx (..)
    , SubmitTxResponse (..)

    , Acquire (..)
    , AcquireResponse (..)
    , Release (..)
    , Query (..)
    , SomeQuery (..)
    , QueryResponse (..)
    ) where

import Prelude

import Cardano.Network.Protocol.NodeToClient
    ( Clients (..) )
import Control.Concurrent.Async
    ( async, link )
import Control.Concurrent.STM
    ( atomically )
import Control.Concurrent.STM.TQueue
    ( newTQueueIO, readTQueue, tryReadTQueue, writeTQueue )
import Control.Exception
    ( IOException )
import Control.Monad
    ( forever, guard )
import Control.Monad.Class.MonadThrow
    ( MonadThrow )
import Control.Tracer
    ( Tracer, traceWith )
import Data.Aeson
    ( FromJSON (..), ToJSON (..), (.=) )
import Data.ByteString
    ( ByteString )
import Data.Functor
    ( ($>) )
import Data.Proxy
    ( Proxy (..) )
import GHC.Generics
    ( Generic )
import Network.TypedProtocol.Pipelined
    ( Nat (..), natToInt )
import Ogmios.Trace
    ( TraceOgmios (..) )
import Ouroboros.Network.Block
    ( Point (..), Tip (..) )
import Ouroboros.Network.Protocol.ChainSync.ClientPipelined
    ( ChainSyncClientPipelined (..)
    , ClientPipelinedStIdle (..)
    , ClientPipelinedStIntersect (..)
    , ClientStNext (..)
    )
import Ouroboros.Network.Protocol.LocalStateQuery.Client
    ( LocalStateQueryClient (..) )
import Ouroboros.Network.Protocol.LocalStateQuery.Type
    ( AcquireFailure )
import Ouroboros.Network.Protocol.LocalTxSubmission.Client
    ( LocalTxClientStIdle (..), LocalTxSubmissionClient (..) )
import Ouroboros.Network.Protocol.LocalTxSubmission.Type
    ( SubmitResult (..) )

import qualified Codec.Json.Wsp as Wsp
import qualified Codec.Json.Wsp.Handler as Wsp
import qualified Data.Aeson as Json
import qualified Data.ByteString.Lazy as BL
import qualified Network.WebSockets as WS
import qualified Ouroboros.Consensus.Ledger.Abstract as Ledger
import qualified Ouroboros.Network.Protocol.LocalStateQuery.Client as LSQ

--  _____ _           _         _____
-- /  __ \ |         (_)       /  ___|
-- | /  \/ |__   __ _ _ _ __   \ `--. _   _ _ __   ___
-- | |   | '_ \ / _` | | '_ \   `--. \ | | | '_ \ / __|
-- | \__/\ | | | (_| | | | | | /\__/ / |_| | | | | (__
--  \____/_| |_|\__,_|_|_| |_| \____/ \__, |_| |_|\___|
--                                     __/ |
--                                    |___/

data FindIntersect block
    = FindIntersect { points :: [Point block] }
    deriving (Generic, Show)

data FindIntersectResponse block
    = IntersectionFound { point :: Point block, tip :: Tip block }
    | IntersectionNotFound { tip :: Tip block }
    deriving (Generic, Show)

data RequestNext
    = RequestNext
    deriving (Generic, Show)

data RequestNextResponse block
    = RollForward { block :: block, tip :: Tip block }
    | RollBackward { point :: Point block, tip :: Tip block }
    deriving (Generic, Show)

mkChainSyncClient
    :: forall m block.
        ( FromJSON (Point block)
        , ToJSON block
        , ToJSON (Point block)
        , ToJSON (Tip block)
        , Monad m
        )
    => Queue (RequestNextResponse block -> Wsp.Response (RequestNextResponse block)) m
    -> SimplePipe ByteString ByteString m
    -> ChainSyncClientPipelined block (Tip block) m ()
mkChainSyncClient Queue{push,pop,tryPop} SimplePipe{await,tryAwait,yield,pass} =
    ChainSyncClientPipelined (clientStIdle Zero)
  where
    clientStIdle
        :: forall n. Nat n
        -> m (ClientPipelinedStIdle n block (Tip block) m ())
    clientStIdle Zero = await >>= Wsp.handle
        (\bytes -> pass bytes *> clientStIdle Zero)
        [ Wsp.Handler $ \FindIntersect{points} ->
            pure . SendMsgFindIntersect points . clientStIntersect

        , Wsp.Handler $ \RequestNext toResponse -> do
            let collect = CollectResponse
                    (Just $ clientStIdle (Succ Zero))
                    (clientStNext Zero pop)
            push toResponse $> SendMsgRequestNextPipelined collect
        ]
    clientStIdle n@(Succ prev) = tryAwait >>= \case
        -- If there's no immediate incoming message, we take this opportunity to
        -- wait and collect one response.
        Nothing -> tryPop >>= \case
            Nothing ->
                clientStIdle n
            Just toResponse ->
                pure $ CollectResponse Nothing (clientStNext prev $ pure toResponse)

        -- Yet, if we have already received a new message from the client, we
        -- prioritize it and pipeline it right away unless there are already too
        -- many requests in flights.
        Just msg -> Wsp.handle
            (\bytes -> pass bytes *> clientStIdle n)
            [ Wsp.Handler $ \RequestNext toResponse -> do
                let collect = CollectResponse
                        (guard (natToInt n < 1000) $> clientStIdle (Succ n))
                        (clientStNext n pop)
                push toResponse $> SendMsgRequestNextPipelined collect
            ] msg

    clientStIntersect
        :: (FindIntersectResponse block -> Wsp.Response (FindIntersectResponse block))
        -> ClientPipelinedStIntersect block (Tip block) m ()
    clientStIntersect toResponse = ClientPipelinedStIntersect
        { recvMsgIntersectFound = \point tip -> do
            yield $ json $ toResponse $ IntersectionFound point tip
            clientStIdle Zero
        , recvMsgIntersectNotFound = \tip -> do
            yield $ json $ toResponse $ IntersectionNotFound tip
            clientStIdle Zero
        }

    clientStNext
        :: Nat n
        -> m (RequestNextResponse block -> Wsp.Response (RequestNextResponse block))
        -> ClientStNext n block (Tip block) m ()
    clientStNext n pop' = ClientStNext
        { recvMsgRollForward = \block tip -> do
            toResponse <- pop'
            yield $ json $ toResponse $ RollForward block tip
            clientStIdle n
        , recvMsgRollBackward = \point tip -> do
            toResponse <- pop'
            yield $ json $ toResponse $ RollBackward point tip
            clientStIdle n
        }

--  _____      _____       _               _         _
-- |_   _|    /  ___|     | |             (_)       (_)
--   | |_  __ \ `--. _   _| |__  _ __ ___  _ ___ ___ _  ___  _ __
--   | \ \/ /  `--. \ | | | '_ \| '_ ` _ \| / __/ __| |/ _ \| '_ \
--   | |>  <  /\__/ / |_| | |_) | | | | | | \__ \__ \ | (_) | | | |
--   \_/_/\_\ \____/ \__,_|_.__/|_| |_| |_|_|___/___/_|\___/|_| |_|

data SubmitTx tx
    = SubmitTx { bytes :: tx }
    deriving (Generic, Show)

data SubmitTxResponse e
    = SubmitTxResponse { error :: SubmitResult e }
    deriving (Generic, Show)

instance Show e => Show (SubmitResult e) where
    show = \case
        SubmitSuccess ->"SubmitSuccess"
        SubmitFail e -> "SubmitFail " <> show e

mkLocalTxSubmissionClient
    :: forall m tx err.
        ( FromJSON tx
        , ToJSON err
        , Monad m
        )
    => SimplePipe ByteString ByteString m
    -> LocalTxSubmissionClient tx err m ()
mkLocalTxSubmissionClient SimplePipe{await,yield,pass} =
     LocalTxSubmissionClient clientStIdle
  where
    clientStIdle
        :: m (LocalTxClientStIdle tx err m ())
    clientStIdle = await >>= Wsp.handle
        (\bytes -> pass bytes *> clientStIdle)
        [ Wsp.Handler $ \SubmitTx{bytes} toResponse ->
            pure $ SendMsgSubmitTx bytes $ \e -> do
                yield $ json $ toResponse $ SubmitTxResponse e
                clientStIdle
        ]

--  _____ _        _         _____
-- /  ___| |      | |       |  _  |
-- \ `--.| |_ __ _| |_ ___  | | | |_   _  ___ _ __ _   _
--  `--. \ __/ _` | __/ _ \ | | | | | | |/ _ \ '__| | | |
-- /\__/ / || (_| | ||  __/ \ \/' / |_| |  __/ |  | |_| |
-- \____/ \__\__,_|\__\___|  \_/\_\\__,_|\___|_|   \__, |
--                                                  __/ |
--                                                 |___/

data Acquire point
    = Acquire { point :: point }
    deriving (Generic, Show)

data AcquireResponse point
    = AcquireSuccess { acquired :: point }
    | AcquireFailed { failure :: AcquireFailure }
    deriving (Generic, Show)

data Release
    = Release
    deriving (Generic, Show)

data Query block = Query { query :: SomeQuery block }
    deriving (Generic)

data SomeQuery block = forall result. SomeQuery
    { query :: Ledger.Query block result
    , encodeResult :: result -> Json.Value
    }

newtype QueryResponse =
    QueryResponse { unQueryResponse :: Json.Value }
    deriving (Generic, Show)

-- data CodecStateQuery block = CodecStateQuery
--     { encodeResult :: forall result. Ledger.Query block result -> result -> Json.Value
--     , parseQuery :: forall result. Json.Value -> Json.Parser (Ledger.Query block result)
--     }

mkLocalStateQueryClient
    :: forall m block point.
        ( MonadThrow m
        , ToJSON point
        , ToJSON AcquireFailure
        , FromJSON point
        , FromJSON (SomeQuery block)
        , point ~ Point block
        )
    => SimplePipe ByteString ByteString m
    -> LocalStateQueryClient block (Ledger.Query block) m ()
mkLocalStateQueryClient SimplePipe{await,yield,pass} =
    LocalStateQueryClient clientStIdle
  where
    clientStIdle
        :: m (LSQ.ClientStIdle block (Ledger.Query block) m ())
    clientStIdle = await >>= Wsp.handle
        (\bytes -> pass bytes *> clientStIdle)
        [ Wsp.Handler $ \(Acquire pt) toResponse ->
            pure $ LSQ.SendMsgAcquire pt (clientStAcquiring pt toResponse)
        , Wsp.Handler $ \Release _toResponse ->
            clientStIdle
        ]

    clientStAcquiring
        :: point
        -> (AcquireResponse point -> Wsp.Response (AcquireResponse point))
        -> LSQ.ClientStAcquiring block (Ledger.Query block) m ()
    clientStAcquiring pt toResponse = LSQ.ClientStAcquiring
        { recvMsgAcquired = do
            yield $ json $ toResponse $ AcquireSuccess pt
            clientStAcquired
        , recvMsgFailure = \failure -> do
            yield $ json $ toResponse $ AcquireFailed failure
            clientStIdle
        }

    clientStAcquired
        :: m (LSQ.ClientStAcquired block (Ledger.Query block) m ())
    clientStAcquired = await >>= Wsp.handle
        (\bytes -> pass bytes *> clientStAcquired)
        [ Wsp.Handler $ \(Acquire pt) toResponse ->
            pure $ LSQ.SendMsgReAcquire pt (clientStAcquiring pt toResponse)
        , Wsp.Handler $ \Release _toResponse ->
            pure $ LSQ.SendMsgRelease clientStIdle
        , Wsp.Handler $ \(Query (SomeQuery query encodeResult)) toResponse ->
            pure $ LSQ.SendMsgQuery query $ LSQ.ClientStQuerying
                { recvMsgResult = \result -> do
                    yield $ json $ toResponse $ QueryResponse $ encodeResult result
                    clientStAcquired
                }
        ]

--  _   _      _
-- | | | |    | |
-- | |_| | ___| |_ __   ___ _ __ ___
-- |  _  |/ _ \ | '_ \ / _ \ '__/ __|
-- | | | |  __/ | |_) |  __/ |  \__ \
-- \_| |_/\___|_| .__/ \___|_|  |___/
--              | |
--              |_|

-- | WebSocket 'Connection', connects all Ouroboros clients together from a
-- single WebSocket connections. It works by constructing simple pipes using
-- queues between clients. Messages first flow through the chain sync clients
-- (as it is the one with the main performance constraints and which will likely
-- process the most messages) and, are passed onto the next client if the
-- message were not recognized as a 'chainSync' message. Here's a little
-- diagram:
--
--     *---------------------------------------------------------------------*
--     |                                                                     |
--     v                     pass                  pass                fail  |
-- WebSocket --> Chain Sync ------> Tx Submission ------> State Query ------>*
--     ^             |                    |                   |
--     |             | yield              | yield             | yield
--     |             v                    v                   v
--     *------------<*<------------------<*<------------------*
--
pipeClients
    :: forall block tx err.
        ( ToJSON block
        , ToJSON (Point block)
        , ToJSON (Tip block)
        , ToJSON err
        , ToJSON AcquireFailure
        , FromJSON (Point block)
        , FromJSON (SomeQuery block)
        , FromJSON tx
        )
    => WS.Connection
    -> IO (Clients IO block tx err)
pipeClients conn = do
    chainSyncQ    <- newTQueueIO
    txSubmissionQ <- newTQueueIO
    stateQueryQ   <- newTQueueIO

    -- Chain Sync
    chainSyncInternalQueue <- newQueue
    let chainSyncClient = mkChainSyncClient chainSyncInternalQueue $ SimplePipe
            { await = atomically $ readTQueue chainSyncQ
            , tryAwait = atomically $ tryReadTQueue chainSyncQ
            , pass  = atomically . writeTQueue txSubmissionQ
            , yield
            }

    -- Tx Submission
    let localTxSubmissionClient = mkLocalTxSubmissionClient $ SimplePipe
            { await = atomically $ readTQueue txSubmissionQ
            , tryAwait = atomically $ tryReadTQueue txSubmissionQ
            , pass = atomically . writeTQueue stateQueryQ
            , yield
            }

    -- State Query
    let localStateQueryClient = mkLocalStateQueryClient $ SimplePipe
            { await = atomically $ readTQueue stateQueryQ
            , tryAwait = atomically $ tryReadTQueue stateQueryQ
            , pass = const defaultHandler
            , yield
            }

    -- Receiving loop
    link =<< async (forever $ receive chainSyncQ)
    pure Clients
        { chainSyncClient
        , localTxSubmissionClient
        , localStateQueryClient
        }
  where
    -- Responses are always sent through the same connection
    yield = WS.sendTextData conn

    -- Push every received messages into a first queue
    receive source = WS.receiveData conn >>= atomically . writeTQueue source

    -- | A default handler for unmatched requests.
    defaultHandler :: IO ()
    defaultHandler = WS.sendTextData conn $ json $ Wsp.clientFault
        "Invalid request: no route found for the given request. Verify the \
        \request's name and/or parameters."

-- | Provide a handler for exception arising when trying to connect to a node
-- that is down.
handleIOException
    :: Tracer IO TraceOgmios
    -> WS.Connection
    -> IOException
    -> IO ()
handleIOException tr conn e = do
    traceWith tr $ OgmiosFailedToConnect e
    let msg = "Connection with the node lost or failed."
    WS.sendClose conn $ json $ Wsp.serverFault msg

data SimplePipe input output (m :: * -> *) = SimplePipe
    { await :: m input
        -- ^ Await for the next input. Block until an input is available.

    , tryAwait :: m (Maybe input)
        -- ^ Return 'Just input' if there's an input available, nothing
        -- otherwise. Non blocking.

    , yield :: output -> m ()
        -- ^ Yield a result.

    , pass  :: input -> m ()
        -- ^ Pass the input onto another component
    }

data Queue a (m :: * -> *) = Queue
    { pop :: m a
        -- ^ Unstash a value. Block until one is available
        --
    , tryPop :: m (Maybe a)
        -- ^ Unstash a value, if any.

    , push :: a -> m ()
        -- ^ Stash a value for later.
    }

newQueue :: IO (Queue a IO)
newQueue = do
    resp <- newTQueueIO
    return Queue
        { pop = atomically $ readTQueue resp
        , tryPop = atomically $ tryReadTQueue resp
        , push  = atomically . writeTQueue resp
        }

--
-- ToJSON / FromJSON instances. Nothing to see here.
--

-- | Helper function to yield a value that is serialisable to JSON.
json :: forall a. ToJSON a => a -> ByteString
json = BL.toStrict . Json.encode

type instance Wsp.ServiceName (Wsp.Response _) = "ogmios"

instance
    ( FromJSON (Point block)
    ) => FromJSON (Wsp.Request (FindIntersect block))
  where
    parseJSON = Wsp.genericFromJSON Wsp.defaultOptions

instance FromJSON (Wsp.Request RequestNext)
  where
    parseJSON = Wsp.genericFromJSON Wsp.defaultOptions

instance
    ( ToJSON (Point block)
    , ToJSON (Tip block)
    ) => ToJSON (Wsp.Response (FindIntersectResponse block))
  where
    toJSON = Wsp.genericToJSON Wsp.defaultOptions proxy
      where proxy = Proxy @(Wsp.Request (FindIntersect block))

instance
    ( ToJSON block
    , ToJSON (Tip block)
    , ToJSON (Point block)
    ) => ToJSON (Wsp.Response (RequestNextResponse block))
  where
    toJSON = Wsp.genericToJSON Wsp.defaultOptions proxy
      where proxy = Proxy @(Wsp.Request RequestNext)

instance
    ( FromJSON tx
    ) => FromJSON (Wsp.Request (SubmitTx tx))
  where
    parseJSON = Wsp.genericFromJSON Wsp.defaultOptions

instance ToJSON e => ToJSON (Wsp.Response (SubmitTxResponse e)) where
    toJSON = Wsp.genericToJSON Wsp.defaultOptions proxy
      where proxy = Proxy @(Wsp.Request (SubmitTx _))

instance ToJSON e => ToJSON (SubmitResult e) where
    toJSON = \case
        SubmitSuccess -> Json.String "SubmitSuccess"
        SubmitFail e  -> Json.object [ "SubmitFail" .= e ]

instance
    ( FromJSON (Point block)
    ) => FromJSON (Wsp.Request (Acquire (Point block)))
  where
    parseJSON = Wsp.genericFromJSON Wsp.defaultOptions

instance
    ( ToJSON AcquireFailure
    , ToJSON (Point block)
    ) => ToJSON (Wsp.Response (AcquireResponse (Point block)))
  where
    toJSON = Wsp.genericToJSON Wsp.defaultOptions proxy
      where proxy = Proxy @(Wsp.Request (Acquire _))

instance FromJSON (Wsp.Request Release)
  where
    parseJSON = Wsp.genericFromJSON Wsp.defaultOptions

instance
    ( FromJSON (SomeQuery block)
    ) => FromJSON (Wsp.Request (Query block))
  where
    parseJSON = Wsp.genericFromJSON Wsp.defaultOptions

instance ToJSON (Wsp.Response QueryResponse)
  where
    toJSON = Wsp.mkResponse Wsp.defaultOptions unQueryResponse proxy
      where proxy = Proxy @(Wsp.Request Release) -- FIXME USE QUERY
