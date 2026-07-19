import { z } from 'zod'
import { DecimalString, IsoDate } from './common'

/**
 * GET .../summary -> { summary: {...} }  (WRAPPED — unlike bare /candles).
 * Percentages are fractions (6dp) and null when net_deposits <= 0 or no benchmark.
 * `as_of` is null before any priced day exists. All numeric fields are decimal strings.
 */
export const summarySchema = z.object({
  current_value: DecimalString,
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
