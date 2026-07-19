import { z } from 'zod'
import { DecimalString, IsoDate } from './common'

/**
 * GET /api/v1/instruments/search?q= ->
 *   { instruments: [{ symbol, name, exchange, asset_type, currency }] }
 * No `id` is returned (transactions POST by symbol); max 20; ordered
 * exact > prefix > name.
 */
export const instrumentSearchResultSchema = z.object({
  symbol: z.string(),
  name: z.string(),
  exchange: z.string(),
  asset_type: z.string(),
  currency: z.string(),
})

export const instrumentSearchSchema = z.object({
  instruments: z.array(instrumentSearchResultSchema),
})

/**
 * GET /api/v1/instruments/:id/price?date= ->
 *   { price: { instrument_id, date, close } }
 * `date` is the trading day actually used (<= requested); before-history
 * returns a 404 `price_unavailable` envelope.
 */
export const priceSchema = z.object({
  instrument_id: z.number(),
  date: IsoDate,
  close: DecimalString,
})

export const priceResponseSchema = z.object({
  price: priceSchema,
})

export type InstrumentSearchResult = z.infer<typeof instrumentSearchResultSchema>
export type InstrumentSearch = z.infer<typeof instrumentSearchSchema>
export type Price = z.infer<typeof priceSchema>
export type PriceResponse = z.infer<typeof priceResponseSchema>
