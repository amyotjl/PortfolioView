import { z } from 'zod'
import { DecimalString, IsoDate } from './common'

/**
 * GET .../holdings?instrument_id=&as_of= ->
 *   { holding: { instrument_id, as_of, shares } }
 * Sell-form pre-flight. `as_of` echoes the request; shares are computed at the
 * last trading day <= as_of. Unknown / flat position -> "0.0" with a 200.
 */
export const holdingSchema = z.object({
  instrument_id: z.number(),
  as_of: IsoDate,
  shares: DecimalString,
})

export const holdingResponseSchema = z.object({
  holding: holdingSchema,
})

export type Holding = z.infer<typeof holdingSchema>
export type HoldingResponse = z.infer<typeof holdingResponseSchema>
