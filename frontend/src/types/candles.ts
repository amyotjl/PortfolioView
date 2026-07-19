import { z } from 'zod'
import { DecimalString, IsoDate } from './common'

/**
 * GET .../candles?from&to&benchmark=true
 *
 * IMPORTANT: this endpoint returns a **bare top-level object** (no wrapper key),
 * unlike /summary and /allocations which are wrapped. Modelled exactly as-built
 * (see docs/API_SHAPES.md "Known envelope inconsistency" — do not "fix" it here).
 *
 * The benchmark is a close-value LINE, never candles: a single ETF's real H/L
 * would falsely make the portfolio (whose H/L are documented bounds) look more
 * volatile.
 */

/** Portfolio value candle. o/h/l/c are decimal strings; H/L are documented bounds. */
export const candleSchema = z.object({
  t: IsoDate,
  o: DecimalString,
  h: DecimalString,
  l: DecimalString,
  c: DecimalString,
})

/** Benchmark close-value line point. */
export const benchmarkLinePointSchema = z.object({
  t: IsoDate,
  v: DecimalString,
})

export const benchmarkLineSchema = z.object({
  symbol: z.string(),
  values: z.array(benchmarkLinePointSchema),
})

/** One instrument's contribution to a day's net flow (DRIP is excluded from flows). */
export const flowItemSchema = z.object({
  ticker: z.string(),
  kind: z.enum(['buy', 'sell']),
  amount: DecimalString, // signed: buy +, sell -
})

export const flowSchema = z.object({
  t: IsoDate,
  net: DecimalString, // signed net cash flow for the day
  items: z.array(flowItemSchema),
})

/** Drawdown fraction (8dp) from the ALL-TIME peak. */
export const drawdownPointSchema = z.object({
  t: IsoDate,
  v: DecimalString,
})

export const candlesMetaSchema = z.object({
  partial: z.boolean(),
  filled_dates: z.array(IsoDate),
  benchmark_clamped: z.boolean(),
  approximation: z.string(),
})

/** Top-level, unwrapped response object. */
export const candlesResponseSchema = z.object({
  candles: z.array(candleSchema),
  benchmark: benchmarkLineSchema.nullable(),
  flows: z.array(flowSchema),
  drawdown: z.array(drawdownPointSchema),
  meta: candlesMetaSchema,
})

export type Candle = z.infer<typeof candleSchema>
export type BenchmarkLinePoint = z.infer<typeof benchmarkLinePointSchema>
export type BenchmarkLine = z.infer<typeof benchmarkLineSchema>
export type FlowItem = z.infer<typeof flowItemSchema>
export type Flow = z.infer<typeof flowSchema>
export type DrawdownPoint = z.infer<typeof drawdownPointSchema>
export type CandlesMeta = z.infer<typeof candlesMetaSchema>
export type CandlesResponse = z.infer<typeof candlesResponseSchema>
