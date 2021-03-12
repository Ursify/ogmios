import {
  createStateQueryClient,
  ledgerTip
} from '@src/StateQuery'
import {
  Hash16,
  Slot
} from '@src/schema'
import { eraStart } from '@src/StateQuery/eraStart'

describe('Local state queries', () => {
  describe('StateQueryClient', () => {
    it('gets the point from the tip if none provided', async () => {
      const client = await createStateQueryClient()
      const { point } = client as { point: { hash: string, slot: number } }
      expect(point.slot).toBeDefined()
      expect(point.hash).toBeDefined()
      await client.release()
    })

    it('uses the provided point for reproducible queries across clients', async () => {
      const client = await createStateQueryClient()
      const anotherClient = await createStateQueryClient({ point: client.point })
      expect(anotherClient.point).toEqual(client.point)
      await client.release()
      await anotherClient.release()
    })

    it('rejects if the provided point is too old', async () => {
      const createWithOldPoint = async () => {
        await createStateQueryClient({
          point: 'origin'
        })
      }
      await expect(createWithOldPoint).rejects
    })

    describe('ledgerTip', () => {
      it('fetches the tip of the ledger', async () => {
        const client = await createStateQueryClient()
        const point = await client.ledgerTip() as { slot: Slot, hash: Hash16 }
        expect(point.hash).toBeDefined()
        expect(point.slot).toBeDefined()
        await client.release()
      })
    })
  })

  describe('Queries', () => {
    describe('eraStart', () => {
      it('fetches the bound of the current era', async () => {
        const bound = await eraStart()
        expect(bound.time).toBeDefined()
        expect(bound.slot).toBeDefined()
        expect(bound.epoch).toBeDefined()
      })
    })
    describe('ledgerTip', () => {
      it('fetches the tip of the ledger', async () => {
        const point = await ledgerTip() as { slot: Slot, hash: Hash16 }
        expect(point.hash).toBeDefined()
        expect(point.slot).toBeDefined()
      })
    })
  })
})
