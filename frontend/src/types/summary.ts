import { z } from 'zod'
import { cashBasisSchema } from './cash'
import { DecimalString, IsoDate } from './common'

/**
 * GET .../summary -> { summary: {...} }  (WRAPPED — unlike bare /candles).
 * Percentages are fractions (6dp) and null when net_deposits <= 0 or no benchmark.
 * `as_of` is null before any priced day exists. All numeric fields are decimal strings.
 *
 * CASH (#80). Five fields are additive, and one of them is the single most
 * dangerous nullable in the app:
 *
 *   | field           | tracks cash          | does not track cash          |
 *   |-----------------|----------------------|------------------------------|
 *   | current_value   | holdings + cash      | holdings                     |
 *   | holdings_value  | holdings             | == current_value             |
 *   | cash_balance    | signed balance       | **null**                     |
 *   | net_deposits    | deposits - withdrawals | sum of trade cost (as before) |
 *   | deposit_basis   | 'cash'               | 'trades'                     |
 *
 * `cash_balance` MUST NOT be defaulted. It is `.nullable()` and NOTHING ELSE —
 * no `.optional()`, no `.default('0.00')`, and no `?? 0` at any consumer. `null`
 * means "does not track cash"; `'0.00'` means "tracks cash, exactly flat". A
 * payload that omits the key entirely must FAIL parsing (see types/schemas.spec.ts)
 * rather than being silently read as flat, because a single default anywhere in
 * this chain turns every existing portfolio's dashboard into a lie.
 *
 * Invariant, pinned by contract test rather than recomputed here:
 *   current_value == holdings_value + cash_balance   when tracked
 *   current_value == holdings_value                  when not
 */
export const summarySchema = z.object({
  current_value: DecimalString,
  holdings_value: DecimalString,
  cash_balance: DecimalString.nullable(),
  deposit_basis: cashBasisSchema,
  cash_negative: z.boolean(),
  cash_negative_since: IsoDate.nullable(),
  net_deposits: DecimalString,
  total_return: DecimalString,
  total_return_pct: DecimalString.nullable(),
  benchmark_return_pct: DecimalString.nullable(),
  vs_benchmark_edge_pct: DecimalString.nullable(),
  max_drawdown_pct: DecimalString,
  as_of: IsoDate.nullable(),
})

export const summaryResponseSchema = z.object({
  summary: summarySchema,
})

export type Summary = z.infer<typeof summarySchema>
export type SummaryResponse = z.infer<typeof summaryResponseSchema>
