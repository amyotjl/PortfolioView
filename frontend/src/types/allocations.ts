import { z } from 'zod'
import { DecimalString, IsoDate } from './common'

/**
 * GET .../allocations -> { allocations: {...} }  (WRAPPED — unlike bare /candles).
 * Largest-first; weights sum to 1; sectorless instruments bucket under "ETF / Fund".
 * `symbol` on a by_instrument row is nullable; values/weights are decimal strings.
 *
 * `sector` on a by_instrument row is NOT nullable — the server always emits a
 * label, falling back to "ETF / Fund" — and is byte-identical to the matching
 * by_sector row's label. That makes it the join key the sector treemap groups on
 * (docs/API_SHAPES.md); the two breakdowns have no other key in common.
 */
export const allocationByInstrumentSchema = z.object({
  instrument_id: z.number(),
  symbol: z.string().nullable(),
  sector: z.string(),
  value: DecimalString,
  weight: DecimalString,
})

export const allocationBySectorSchema = z.object({
  sector: z.string(),
  value: DecimalString,
  weight: DecimalString,
})

export const allocationsSchema = z.object({
  as_of: IsoDate.nullable(),
  total_value: DecimalString,
  by_instrument: z.array(allocationByInstrumentSchema),
  by_sector: z.array(allocationBySectorSchema),
})

export const allocationsResponseSchema = z.object({
  allocations: allocationsSchema,
})

export type AllocationByInstrument = z.infer<typeof allocationByInstrumentSchema>
export type AllocationBySector = z.infer<typeof allocationBySectorSchema>
export type Allocations = z.infer<typeof allocationsSchema>
export type AllocationsResponse = z.infer<typeof allocationsResponseSchema>
