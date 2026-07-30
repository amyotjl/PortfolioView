import { z } from 'zod'
import { DecimalString, IsoDate } from './common'

/**
 * GET /api/v1/instruments/search?q= ->
 *   { instruments: [{ symbol, name, exchange, asset_type, currency }] }
 * No `id` is returned (transactions POST by symbol); max 20. Ordering is five
 * tiers then alphabetical — match band, tradeable, live, asset class, symbol
 * length (issue #63; see docs/API_SHAPES.md). Ordering matters because the
 * result set is CAPPED: a weak sort silently truncates the row the user meant
 * rather than returning a wrong one.
 *
 * Only `symbol` is NOT NULL (db/schema.rb on listed_instruments); the serializer
 * emits columns raw, and `exchange`/`asset_type`/`currency` can be null too.
 * `name` was null on every row until #63 and is now backfilled from FMP metadata
 * for symbols the user has touched — so coverage is PARTIAL and grows over time.
 * Keep it `.nullable()`: most of the 106k-row directory still has no name.
 * Same nullable-column precedent as allocations by_instrument.symbol.
 */
export const instrumentSearchResultSchema = z.object({
  symbol: z.string(),
  name: z.string().nullable(),
  exchange: z.string().nullable(),
  asset_type: z.string().nullable(),
  currency: z.string().nullable(),
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
