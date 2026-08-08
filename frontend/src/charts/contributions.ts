/**
 * Pure builder for the contribution-vs-growth stacked area (backlog #048 / #52).
 *
 * The question it answers: of what this portfolio is worth today, how much did the
 * user PUT IN and how much did the market ADD? Both series are derived entirely
 * client-side from the /candles payload — closes for total value, `flows[].net` for
 * external cash movement (DRIP is already excluded from flows server-side, so
 * reinvested dividends correctly count as growth, not as a contribution).
 *
 * THE WINDOW BASELINE (the one modelling decision worth understanding)
 * -------------------------------------------------------------------
 * /candles returns flows only for the *requested range*, so a cumulative sum of
 * them is not lifetime contributed capital whenever the range starts after the
 * portfolio's inception — the value already standing on day one was paid for by
 * contributions the payload doesn't contain, and their cost basis is unknowable
 * from this endpoint.
 *
 * So the contribution baseline is the **window-opening value**: the first candle's
 * open. The chart then reads as "growth *within the selected range*" — on the first
 * day growth is exactly that day's mark-to-market move, and thereafter growth is
 * every change in value that cash flows do not explain. That is self-consistent at
 * any range, needs no second request, and never presents a partial flow history as
 * if it were a full one. The caller surfaces this in the card caption; `baseCents`
 * is returned so it can.
 *
 * WHICH FLOWS THE BASELINE ALREADY CONTAINS (subtle, and it caused a real bug)
 * ---------------------------------------------------------------------------
 * A candle's `o` is NOT "the value before that day's trades". Portfolios::Valuation
 * values each day's END-OF-DAY share count at that day's OPENING price
 * (app/services/portfolios/valuation.rb — `open += shares * po`, where `shares` is
 * holdings[date], i.e. after the date's transactions). So the first candle's open
 * already reflects every trade dated on or before it.
 *
 * Therefore only flows dated strictly AFTER the first candle may be added to the
 * baseline. Adding the first day's flow on top of `o` double-counts that purchase
 * and invents a shortfall band on day one that is not in the data — which is
 * exactly what happened, and what a fixture written against the wrong assumption
 * about `o` could not catch. It took looking at the rendered chart.
 *
 * CASH (#80), AND WHY THE DISCARD RULE ABOVE IS UNCHANGED
 * ------------------------------------------------------
 * When a portfolio tracks cash, total value is holdings + cash, so exactly two
 * expressions change: `value` becomes the candle close PLUS cash on that day, and
 * `baseCents` becomes the first candle's open PLUS cash on the first candle's day.
 * Nothing else — in particular `flows.filter(f => f.t > first.t)` stays EXACTLY as
 * written.
 *
 * That is not a lucky coincidence, it is the same convention twice: `/candles`'
 * `cash` series is END-OF-DAY, so its first point already contains every cash
 * movement dated on or before the first candle, precisely as `o` already contains
 * every trade dated on or before it. Same convention, same discard rule, no new
 * logic. A START-of-day cash series would double-count day one and reproduce the
 * phantom band described above — which is why the pair of fixtures in the spec
 * (a deposit on day one, and the same portfolio with it on day two) is the test
 * that matters: a single fixture is what CONFIRMED the #52 bug instead of catching
 * it.
 *
 * What this buys is the thing the chart previously could not express: a trade
 * becomes VALUE-NEUTRAL (money moves from cash into holdings, total unchanged),
 * and idle cash is finally *in* the value line instead of silently omitted.
 *
 * When `payload.cash === null` every cash lookup is 0 and the output is
 * byte-identical to before this feature. That is the no-regression pin.
 *
 * NEGATIVE GROWTH (the documented rendering choice #52 asks for)
 * -------------------------------------------------------------
 * A stack cannot hold a negative band: ECharts stacks negatives downward from
 * zero, which would draw a loss hanging below the axis instead of below the
 * contributions line. So growth is split into two mutually exclusive bands over a
 * clipped floor — at any date exactly one of them is non-zero:
 *
 *   floor     = min(contributed, value)      capital band (blue)
 *   gain      = max(0, value - contributed)  stacked above floor (up token)
 *   shortfall = max(0, contributed - value)  stacked above floor (down token)
 *
 * The stack top is therefore always max(contributed, value), and the separately
 * plotted total-value line sits at `value` — at the top of the stack when there is
 * a gain, and at the gain/shortfall boundary when the portfolio is under water. A
 * reader sees the blue band truncated at the value line with a red band completing
 * it up to the contributions level: "this is what you have, that gap is how far
 * below your contributions you are."
 *
 * This split is also what makes the up/down pair legal at its CVD separation floor
 * (ΔE 6.8 deutan — see the `capital` note in theme.ts). Identity never rests on
 * hue: the two bands never coexist at one date, they sit on opposite sides of the
 * value line, each band's top edge is a 2px surface-colored separator, the legend
 * is always present, and the tooltip and table twin both carry a signed growth
 * figure.
 *
 * Money is summed in exact integer cents (lib/money.ts), not floats: cumulative
 * flow is a running sum and growth is a difference of two large near-equal sums.
 * Conversion to plotting numbers happens only at the series boundary, and every
 * displayed figure goes back through the decimal-string formatters.
 */
import type { EChartsOption } from 'echarts'
import type { CandlesResponse } from '@/types'
import type { ChartTheme } from './theme'
import { escapeHtml } from './colors'
import { centsToDecimalString, centsToDollars, toCents } from '@/lib/money'
import { formatCompactCurrency, formatCurrency, formatDate } from '@/lib/format'

export const CAPITAL_SERIES = 'Contributed capital'
export const GAIN_SERIES = 'Growth'
export const SHORTFALL_SERIES = 'Below contributions'
export const VALUE_SERIES = 'Total value'

/** One trading day of the derivation. All figures are exact integer cents. */
export interface ContributionPoint {
  t: string
  /** Total value — the day's holdings close PLUS that day's cash balance. */
  valueCents: number
  /** Window-opening value plus every net flow up to and including this date. */
  contributedCents: number
  /** `value - contributed`; negative when the portfolio is below its contributions. */
  growthCents: number
}

export interface Contributions {
  /** The window-opening value the contribution baseline starts from. */
  baseCents: number
  points: ContributionPoint[]
}

/**
 * Derive the contribution/growth series from a /candles payload. Pure, and safe on
 * an empty payload (yields no points and a zero base rather than throwing).
 *
 * Flows are accumulated by DATE ORDER rather than by index, and a flow dated
 * between two candles accrues at the next candle — so a flow on a day that is not
 * itself in the candle list is still counted exactly once, and never dropped.
 * Unparseable money is treated as a zero delta rather than poisoning the running
 * sum with NaN for every later date.
 *
 * Flows dated on or before the first candle are DISCARDED, not accumulated: the
 * baseline already contains them (see the note above).
 */
export function deriveContributions(payload: CandlesResponse): Contributions {
  const first = payload.candles[0]
  if (!first) return { baseCents: 0, points: [] }

  /*
   * END-OF-DAY cash by date; an empty map when the portfolio does not track cash, so
   * every lookup below is 0 and the derivation collapses to its pre-#80 form. The
   * backend emits one point per swept day, so a candle date absent from the series
   * means no cash existed yet.
   */
  const cashCentsByDate = new Map<string, number>()
  for (const point of payload.cash ?? []) {
    const cents = toCents(point.v)
    if (cents !== null) cashCentsByDate.set(point.t, cents)
  }
  const cashAt = (date: string): number => cashCentsByDate.get(date) ?? 0

  // The window-opening TOTAL: holdings at the open plus the cash standing that day.
  const baseCents = (toCents(first.o) ?? 0) + cashAt(first.t)

  // UNCHANGED, and deliberately so — see "CASH … the discard rule" in the module note.
  const flows = payload.flows
    .filter((f) => f.t > first.t)
    .map((f) => ({ t: f.t, netCents: toCents(f.net) ?? 0 }))
    .sort((a, b) => (a.t < b.t ? -1 : a.t > b.t ? 1 : 0))

  let flowIndex = 0
  let contributedCents = baseCents
  const points: ContributionPoint[] = []

  for (const candle of payload.candles) {
    while (flowIndex < flows.length && flows[flowIndex].t <= candle.t) {
      contributedCents += flows[flowIndex].netCents
      flowIndex += 1
    }
    const valueCents = (toCents(candle.c) ?? 0) + cashAt(candle.t)
    points.push({
      t: candle.t,
      valueCents,
      contributedCents,
      growthCents: valueCents - contributedCents,
    })
  }

  return { baseCents, points }
}

/** The clipped capital band: `min(contributed, value)`, in plotting dollars. */
export function floorSeries(points: readonly ContributionPoint[]): number[] {
  return points.map((p) => centsToDollars(Math.min(p.contributedCents, p.valueCents)))
}

/** Growth above contributions: `max(0, growth)`, in plotting dollars. */
export function gainSeries(points: readonly ContributionPoint[]): number[] {
  return points.map((p) => centsToDollars(Math.max(0, p.growthCents)))
}

/** Shortfall below contributions: `max(0, -growth)`, in plotting dollars. */
export function shortfallSeries(points: readonly ContributionPoint[]): number[] {
  return points.map((p) => centsToDollars(Math.max(0, -p.growthCents)))
}

/** Total value line, in plotting dollars. */
export function valueSeries(points: readonly ContributionPoint[]): number[] {
  return points.map((p) => centsToDollars(p.valueCents))
}

/** `+$1,200.00` / `-$340.50` / `$0.00`, at the formatter's full precision. */
export function signedCents(cents: number): string {
  const formatted = formatCurrency(centsToDecimalString(cents))
  return cents > 0 ? `+${formatted}` : formatted
}

// --- Tooltip ---------------------------------------------------------------

function swatch(color: string): string {
  return `<span style="display:inline-block;width:9px;height:9px;border-radius:2px;background:${color};vertical-align:middle;margin-right:6px"></span>`
}

function row(label: string, value: string, theme: ChartTheme, color?: string): string {
  const key = color ? swatch(color) : ''
  return `<div style="display:flex;justify-content:space-between;gap:16px"><span style="color:${theme.inkMuted}">${key}${label}</span><span style="color:${theme.ink};font-weight:600;font-variant-numeric:tabular-nums">${value}</span></div>`
}

/**
 * Tooltip for a hovered date, looked up from the derivation by date rather than
 * read out of ECharts' params — so it unit-tests with `[{ axisValue: '...' }]`.
 */
function renderTooltip(
  params: unknown,
  byDate: Map<string, ContributionPoint>,
  theme: ChartTheme,
): string {
  const arr = Array.isArray(params) ? params : [params]
  const first = arr[0] as { axisValue?: string | number } | undefined
  const date = first?.axisValue
  if (typeof date !== 'string') return ''
  const point = byDate.get(date)
  if (!point) return ''

  const growing = point.growthCents >= 0
  const rows = [
    `<div style="font-weight:600;margin-bottom:4px;color:${theme.ink}">${escapeHtml(formatDate(date))}</div>`,
    row(VALUE_SERIES, formatCurrency(centsToDecimalString(point.valueCents)), theme, theme.ink),
    row(
      CAPITAL_SERIES,
      formatCurrency(centsToDecimalString(point.contributedCents)),
      theme,
      theme.capital,
    ),
    row(
      growing ? GAIN_SERIES : SHORTFALL_SERIES,
      signedCents(point.growthCents),
      theme,
      growing ? theme.up : theme.down,
    ),
  ]
  return `<div style="font-size:12px;line-height:1.5">${rows.join('')}</div>`
}

// --- Option ----------------------------------------------------------------

/**
 * Build the stacked-area option. Pure: `(derivation, theme)` in, `EChartsOption`
 * out; valid (and empty) on a zero-point derivation rather than throwing.
 *
 * Each band's own line is drawn in the SURFACE color at 2px — that is the dataviz
 * "2px surface gap between stacked fills", expressed the only way an ECharts area
 * stack allows, and it is why the fills read as separate bands without a border
 * around them. The true value boundary is the separate ink-colored line series.
 */
export function buildContributionGrowthOption(
  contributions: Contributions,
  theme: ChartTheme,
): EChartsOption {
  const { points } = contributions
  const dates = points.map((p) => p.t)
  const byDate = new Map(points.map((p) => [p.t, p]))

  const band = (name: string, color: string, data: number[]) => ({
    name,
    type: 'line' as const,
    stack: 'contribution',
    data,
    showSymbol: false,
    // Surface-colored 2px edge = the gap between fills (see the note above).
    lineStyle: { width: 2, color: theme.panel },
    areaStyle: { color, opacity: 0.55 },
    // itemStyle is what the LEGEND marker is drawn from — areaStyle is not. Without
    // it ECharts falls back to its own default palette, so the swatches came out
    // blue/green/YELLOW and told the reader nothing about the bands they label.
    // The legend is load-bearing secondary encoding here; it has to be right.
    itemStyle: { color },
    emphasis: { disabled: true },
  })

  return {
    animation: false,
    backgroundColor: 'transparent',
    textStyle: { color: theme.ink },
    legend: {
      top: 0,
      right: 0,
      textStyle: { color: theme.inkMuted },
      data: [CAPITAL_SERIES, GAIN_SERIES, SHORTFALL_SERIES, VALUE_SERIES],
    },
    grid: { left: 62, right: 18, top: 34, bottom: 28 },
    tooltip: {
      trigger: 'axis',
      axisPointer: { type: 'line' },
      backgroundColor: theme.panel,
      borderColor: theme.line,
      textStyle: { color: theme.ink },
      formatter: (params: unknown): string => renderTooltip(params, byDate, theme),
    },
    xAxis: {
      type: 'category',
      data: dates,
      boundaryGap: false,
      axisLine: { lineStyle: { color: theme.line } },
      axisTick: { show: false },
      splitLine: { show: false },
      axisLabel: { color: theme.inkSubtle, formatter: (v: string) => formatDate(v) },
    },
    yAxis: {
      type: 'value',
      scale: false,
      axisLine: { show: false },
      axisTick: { show: false },
      axisLabel: { color: theme.inkSubtle, formatter: formatCompactCurrency },
      splitLine: { lineStyle: { color: theme.line } },
    },
    series: [
      band(CAPITAL_SERIES, theme.capital, floorSeries(points)),
      band(GAIN_SERIES, theme.up, gainSeries(points)),
      band(SHORTFALL_SERIES, theme.down, shortfallSeries(points)),
      {
        name: VALUE_SERIES,
        type: 'line',
        z: 4,
        data: valueSeries(points),
        showSymbol: false,
        lineStyle: { width: 2, color: theme.ink },
        itemStyle: { color: theme.ink },
      },
    ],
  }
}
