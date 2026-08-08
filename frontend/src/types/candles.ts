import { z } from 'zod'
import { cashBasisSchema } from './cash'
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

/**
 * Portfolio value candle. o/h/l/c are decimal strings; H/L are documented bounds.
 *
 * CASH (#80): these legs stay **HOLDINGS ONLY** in both bases. Cash is emitted as
 * its own `cash` series instead of being folded in, for two reasons: the
 * candlestick's grammar says "this is a market move", so a deposit drawn as a
 * tall green candle is a lie about performance; and cash has no O/H/L of its own,
 * so folding it in would dilute the H/L wick whose bounds caveat is already the
 * fragile part of that pane.
 */
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

/**
 * One day's cash balance. SIGNED (an aggregate) and **END-OF-DAY**, so a day's
 * point already contains every movement dated on or before it — exactly the
 * convention a candle's `o` follows for trades. `charts/contributions.ts` depends
 * on that: a start-of-day series would double-count day one and reproduce the #52
 * phantom band.
 */
export const cashPointSchema = z.object({
  t: IsoDate,
  v: DecimalString,
})

/**
 * One contribution to a day's net flow.
 *
 * `kind` is a PLAIN STRING, not an enum: on the cash basis it widens beyond
 * buy|sell to the cash kinds, and a newer backend kind must not throw in dev.
 * `charts/candles.ts` labels it through `flowKindLabel`, which falls through to
 * the raw string, and the flow bars color by the SIGN of `amount` — never by
 * `kind` — so an unknown kind cannot break the chart.
 *
 * `ticker` is nullable: a deposit has no instrument.
 */
export const flowItemSchema = z.object({
  ticker: z.string().nullable(),
  kind: z.string(),
  amount: DecimalString, // signed: money in +, money out -
})

/**
 * A day's net external flow.
 *
 * `flows` is EXCLUSIVE, not additive. On the cash basis it carries ONLY deposits
 * and withdrawals — trades are absent, because under a full cash account a trade
 * is an internal transfer that does not move total value, and a trade bar in a
 * pane whose job is "flows explain value jumps" would be actively misleading. On
 * the trade basis it is byte-identical to before this feature.
 *
 * Invariant (contract test): `sum(flows[].net)` over all time == `summary.net_deposits`,
 * in BOTH bases. `charts/contributions.ts` silently depends on it. If trade bars
 * are ever wanted back they go in a separate `trade_flows` key — never mixed into
 * this array, because Summary sums `flows[].net`.
 */
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
  flow_basis: cashBasisSchema,
  cash_negative: z.boolean(),
  cash_negative_since: IsoDate.nullable(),
})

/**
 * Top-level, unwrapped response object.
 *
 * `cash` is `null` iff the portfolio does not track cash, and it is the
 * DISCRIMINATOR every chart builder reads. Builders branch on `payload.cash !== null`
 * — never on a `summary.deposit_basis` threaded in as an option: a pure builder
 * depending on a second endpoint flickers while that query is pending, and an
 * in-payload discriminator cannot disagree with the payload it labels.
 */
export const candlesResponseSchema = z.object({
  candles: z.array(candleSchema),
  benchmark: benchmarkLineSchema.nullable(),
  cash: z.array(cashPointSchema).nullable(),
  flows: z.array(flowSchema),
  drawdown: z.array(drawdownPointSchema),
  meta: candlesMetaSchema,
})

export type Candle = z.infer<typeof candleSchema>
export type BenchmarkLinePoint = z.infer<typeof benchmarkLinePointSchema>
export type BenchmarkLine = z.infer<typeof benchmarkLineSchema>
export type CashPoint = z.infer<typeof cashPointSchema>
export type FlowItem = z.infer<typeof flowItemSchema>
export type Flow = z.infer<typeof flowSchema>
export type DrawdownPoint = z.infer<typeof drawdownPointSchema>
export type CandlesMeta = z.infer<typeof candlesMetaSchema>
export type CandlesResponse = z.infer<typeof candlesResponseSchema>
