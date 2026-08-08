/**
 * Pure builder for the dashboard's linked multi-pane chart (backlog #041 / #45).
 *
 * ONE ECharts instance, THREE linked grids sharing one crosshair and one
 * dataZoom (docs/PLAN.md § Dashboard):
 *   grid 0 — portfolio candlesticks + benchmark close LINE (top, ~56%)
 *   grid 1 — daily net-cash-flow bars (the "volume" pane; flows explain jumps)
 *   grid 2 — drawdown-from-peak area
 *
 * Everything here is a PURE function of (typed payload + theme tokens + flags):
 * no Vue, no DOM, no ECharts runtime import (types only, erased at build). That
 * is what makes it unit-testable without a browser (backlog #044 / #48).
 *
 * Decimal strings are converted to numbers ONLY here, at the chart boundary —
 * pixels don't need BigDecimal. Displayed money/percent still flow through the
 * decimal-string-safe formatters so the tooltip keeps full precision.
 *
 * Dates stay ISO 'YYYY-MM-DD' strings used directly as category-axis values —
 * never Date objects (that would reintroduce the timezone drift the app avoids).
 */
import type { EChartsOption } from 'echarts'
import type {
  CandlesResponse,
  Candle,
  BenchmarkLine,
  CashPoint,
  Flow,
  DrawdownPoint,
} from '@/types'
import type { ChartTheme } from './theme'
import { escapeHtml } from './colors'
import { cashKindLabel } from '@/lib/cash'
import { centsToDecimalString, toCents } from '@/lib/money'
import { formatCompactCurrency, formatCurrency, formatDate, formatPercent } from '@/lib/format'

export interface DashboardChartOptions {
  /** Include the benchmark close-value line in the price pane. */
  showBenchmark?: boolean
}

/** A single flow bar: value plus its sign-driven color. */
export interface FlowBarPoint {
  value: number
  itemStyle: { color: string }
}

/** Convert a decimal string to a plotting number at the chart boundary. */
function toNum(value: string): number {
  return Number(value)
}

/** ISO trading-day labels for the shared category axis (the candles are master). */
export function extractDates(candles: readonly Candle[]): string[] {
  return candles.map((c) => c.t)
}

/**
 * Candlestick series data in ECharts' required order: [open, close, low, high].
 * (Not o/h/l/c — ECharts wants open, close, lowest, highest.)
 */
export function toCandlestickData(candles: readonly Candle[]): number[][] {
  return candles.map((c) => [toNum(c.o), toNum(c.c), toNum(c.l), toNum(c.h)])
}

/**
 * Align the benchmark close-value line onto the candle date axis. Dates the
 * benchmark doesn't cover (short-history clamp) become `null` so the line simply
 * starts where the data starts instead of stretching a false segment.
 */
export function alignBenchmark(
  dates: readonly string[],
  benchmark: BenchmarkLine | null,
): (number | null)[] {
  if (!benchmark) return dates.map(() => null)
  const byDate = new Map(benchmark.values.map((p) => [p.t, toNum(p.v)]))
  return dates.map((d) => (byDate.has(d) ? (byDate.get(d) as number) : null))
}

/**
 * Net-cash-flow bars aligned to the date axis. Days with no transaction are
 * `null` (no bar); days with a flow get a bar colored by sign — up token for a
 * net contribution (+), down token for a net withdrawal (−). Sign is also
 * carried by the bar's side of the zero baseline and by the signed tooltip
 * value, so meaning never rests on color alone.
 */
export function buildFlowSeriesData(
  dates: readonly string[],
  flows: readonly Flow[],
  theme: ChartTheme,
): (FlowBarPoint | null)[] {
  const byDate = new Map(flows.map((f) => [f.t, toNum(f.net)]))
  return dates.map((d) => {
    if (!byDate.has(d)) return null
    const value = byDate.get(d) as number
    return { value, itemStyle: { color: value >= 0 ? theme.up : theme.down } }
  })
}

/** Drawdown-from-peak fractions aligned to the date axis (≤ 0; null where absent). */
export function alignDrawdown(
  dates: readonly string[],
  drawdown: readonly DrawdownPoint[],
): (number | null)[] {
  const byDate = new Map(drawdown.map((p) => [p.t, toNum(p.v)]))
  return dates.map((d) => (byDate.has(d) ? (byDate.get(d) as number) : null))
}

/** Benchmark legend/series label, e.g. `Benchmark · SPY`. */
export function benchmarkSeriesName(benchmark: BenchmarkLine): string {
  return `Benchmark · ${benchmark.symbol}`
}

/**
 * Cash balances by date, or an EMPTY map when the portfolio does not track cash
 * (#80). The empty map is what makes every cash-aware branch below collapse back to
 * exactly today's output when `payload.cash === null`.
 *
 * The series is END-OF-DAY and the backend emits one point per swept day, so a
 * candle date missing from it means "no cash movement had happened yet" — read as 0.
 */
function cashByDate(cash: readonly CashPoint[] | null): Map<string, number> {
  if (!cash) return new Map()
  const out = new Map<string, number>()
  for (const point of cash) {
    const cents = toCents(point.v)
    if (cents !== null) out.set(point.t, cents)
  }
  return out
}

/**
 * Human label for a flow item's `kind`, falling through to the raw string.
 *
 * `flows[].items[].kind` widens beyond buy|sell on the cash basis, and the schema
 * models it as `z.string()` for that reason. buy/sell are deliberately NOT in the
 * label table: they pass through verbatim, which is what keeps a trade-basis tooltip
 * byte-identical to before this feature. An unrecognised kind renders as itself
 * rather than blanking the row — and the flow bars color by the SIGN of `amount`,
 * never by `kind`, so an unknown kind cannot break the chart either.
 */
export function flowKindLabel(kind: string): string {
  return cashKindLabel(kind)
}

// --- Tooltip ---------------------------------------------------------------

const PORTFOLIO_SERIES = 'Portfolio'
const FLOW_SERIES = 'Net cash flow'
const DRAWDOWN_SERIES = 'Drawdown'

/** `+$1,000.00` for a contribution, `-$500.00` for a withdrawal (precision kept). */
function signedMoney(value: string): string {
  const formatted = formatCurrency(value)
  return Number(value) > 0 ? `+${formatted}` : formatted
}

function lineKey(color: string): string {
  return `<span style="display:inline-block;width:10px;height:2px;background:${color};vertical-align:middle;margin-right:6px"></span>`
}

function metricRow(color: string, label: string, value: string, ink: string, muted: string): string {
  return `<div style="display:flex;justify-content:space-between;gap:16px"><span style="color:${muted}">${lineKey(color)}${label}</span><span style="color:${ink};font-weight:600;font-variant-numeric:tabular-nums">${value}</span></div>`
}

interface TooltipContext {
  candlesByDate: Map<string, Candle>
  benchmarkByDate: Map<string, number>
  /** Empty unless the portfolio tracks cash — see `cashByDate`. */
  cashByDate: Map<string, number>
  tracksCash: boolean
  flowsByDate: Map<string, Flow>
  drawdownByDate: Map<string, number>
  filledDates: Set<string>
  benchmark: BenchmarkLine | null
  showBenchmark: boolean
  approximation: string
  theme: ChartTheme
}

/**
 * Build the shared-axis tooltip for a hovered date. Everything is looked up by
 * date from the payload (not read out of ECharts' params), so the same function
 * is trivially unit-testable: call it with `[{ axisValue: '2026-01-05' }]`.
 */
function renderTooltip(params: unknown, ctx: TooltipContext): string {
  const arr = Array.isArray(params) ? params : [params]
  const first = arr[0] as { axisValue?: string | number } | undefined
  const date = first?.axisValue
  if (typeof date !== 'string') return ''

  const { theme } = ctx
  const rows: string[] = []
  const filled = ctx.filledDates.has(date)
  const heading = `${formatDate(date)}${filled ? ' · forward-filled' : ''}`
  rows.push(
    `<div style="font-weight:600;margin-bottom:4px;color:${theme.ink}">${escapeHtml(heading)}</div>`,
  )

  const candle = ctx.candlesByDate.get(date)
  if (candle) {
    /*
     * THIS IS WHERE "CASH OVER TIME" EARNS ITS PLACE — on demand, for zero pixels.
     * Cash is deliberately in neither the candle nor a fourth series in grid 0: the
     * candlestick's grammar says "this is a market move", so a deposit drawn as a
     * tall green candle is a lie about performance. The tooltip can state the
     * relationship exactly instead.
     *
     * A premise worth recording, because it is the opposite of the obvious guess:
     * with `yAxis[0].scale: true` the axis fits [min, max], so a CONSTANT cash offset
     * would shift both bounds equally and leave visible variance unchanged. The
     * flattening risk comes from cash CHANGING — a $50k mid-window deposit forces the
     * axis to span $50k and collapses the equity's daily wiggles to a pixel or two.
     *
     * When cash is untracked this branch is skipped entirely and the rows below are
     * byte-identical to before #80.
     */
    if (ctx.tracksCash) {
      const holdingsCents = toCents(candle.c)
      const cashCents = ctx.cashByDate.get(date) ?? 0
      if (holdingsCents !== null) {
        rows.push(
          metricRow(
            theme.ink,
            'Total',
            formatCurrency(centsToDecimalString(holdingsCents + cashCents)),
            theme.ink,
            theme.inkMuted,
          ),
        )
      }
      rows.push(
        metricRow(theme.up, 'Holdings', formatCurrency(candle.c), theme.ink, theme.inkMuted),
      )
      rows.push(
        `<div style="color:${theme.inkSubtle};font-size:11px;font-variant-numeric:tabular-nums;margin:1px 0 2px 16px">Open ${formatCurrency(candle.o)} · High ${formatCurrency(candle.h)} · Low ${formatCurrency(candle.l)}</div>`,
      )
      // warn, never `down`: negative cash is a bookkeeping gap, not a loss.
      rows.push(
        metricRow(
          cashCents < 0 ? theme.warn : theme.inkMuted,
          'Cash',
          formatCurrency(centsToDecimalString(cashCents)),
          theme.ink,
          theme.inkMuted,
        ),
      )
    } else {
      rows.push(metricRow(theme.up, 'Close', formatCurrency(candle.c), theme.ink, theme.inkMuted))
      rows.push(
        `<div style="color:${theme.inkSubtle};font-size:11px;font-variant-numeric:tabular-nums;margin:1px 0 2px 16px">Open ${formatCurrency(candle.o)} · High ${formatCurrency(candle.h)} · Low ${formatCurrency(candle.l)}</div>`,
      )
    }
  }

  if (ctx.showBenchmark && ctx.benchmark && ctx.benchmarkByDate.has(date)) {
    const value = ctx.benchmarkByDate.get(date) as number
    rows.push(
      metricRow(
        theme.accent,
        escapeHtml(benchmarkSeriesName(ctx.benchmark)),
        formatCurrency(String(value)),
        theme.ink,
        theme.inkMuted,
      ),
    )
  }

  const flow = ctx.flowsByDate.get(date)
  if (flow) {
    const net = Number(flow.net)
    rows.push(
      metricRow(
        net >= 0 ? theme.up : theme.down,
        'Net flow',
        signedMoney(flow.net),
        theme.ink,
        theme.inkMuted,
      ),
    )
    for (const item of flow.items) {
      // `AAPL buy +$1,000.00` on the trade basis (byte-identical to before #80,
      // because flowKindLabel passes buy/sell through), `Deposit +$5,000.00` on the
      // cash basis — where there is no instrument, so `ticker` is null and the
      // leading token is dropped rather than rendered as "null".
      const prefix = item.ticker === null ? '' : `${escapeHtml(item.ticker)} `
      rows.push(
        `<div style="color:${theme.inkSubtle};font-size:11px;font-variant-numeric:tabular-nums;margin-left:16px">${prefix}${escapeHtml(flowKindLabel(item.kind))} ${signedMoney(item.amount)}</div>`,
      )
    }
  }

  if (ctx.drawdownByDate.has(date)) {
    const value = ctx.drawdownByDate.get(date) as number
    rows.push(
      metricRow(theme.down, 'Drawdown', formatPercent(String(value)), theme.ink, theme.inkMuted),
    )
  }

  if (ctx.approximation) {
    rows.push(
      `<div style="margin-top:6px;padding-top:4px;border-top:1px solid ${theme.line};color:${theme.inkSubtle};font-size:11px;max-width:230px;white-space:normal">${escapeHtml(ctx.approximation)}</div>`,
    )
  }

  return `<div style="font-size:12px;line-height:1.5">${rows.join('')}</div>`
}

// --- Layout ----------------------------------------------------------------

const GRID_LEFT = 62
const GRID_RIGHT = 18

/** Three stacked grids; the price pane takes ~56% of the height (per PLAN.md). */
const GRIDS = [
  { left: GRID_LEFT, right: GRID_RIGHT, top: '9%', height: '54%' },
  { left: GRID_LEFT, right: GRID_RIGHT, top: '69%', height: '11%' },
  { left: GRID_LEFT, right: GRID_RIGHT, top: '85%', height: '10%' },
] as const

function percentAxis(n: number): string {
  return `${(n * 100).toFixed(0)}%`
}

/**
 * Build the full linked-pane ECharts option. Pure: `(payload, theme, opts)` in,
 * `EChartsOption` out. Safe on empty arrays (returns a valid, empty option
 * instead of throwing) so a zero-transaction portfolio never crashes ECharts.
 */
export function buildDashboardChartOption(
  payload: CandlesResponse,
  theme: ChartTheme,
  opts: DashboardChartOptions = {},
): EChartsOption {
  const showBenchmark = opts.showBenchmark ?? false
  const dates = extractDates(payload.candles)
  const hasBenchmarkLine = showBenchmark && payload.benchmark !== null

  /*
   * THE DISCRIMINATOR IS THE PAYLOAD'S OWN `cash`, never a `deposit_basis` threaded
   * in through `opts` from /summary. A pure builder that depends on a second endpoint
   * flickers while that query is pending, and an in-payload discriminator cannot
   * disagree with the payload it labels.
   */
  const tracksCash = payload.cash !== null

  const ctx: TooltipContext = {
    candlesByDate: new Map(payload.candles.map((c) => [c.t, c])),
    benchmarkByDate: new Map((payload.benchmark?.values ?? []).map((p) => [p.t, toNum(p.v)])),
    cashByDate: cashByDate(payload.cash),
    tracksCash,
    flowsByDate: new Map(payload.flows.map((f) => [f.t, f])),
    drawdownByDate: new Map(payload.drawdown.map((p) => [p.t, toNum(p.v)])),
    filledDates: new Set(payload.meta.filled_dates),
    benchmark: payload.benchmark,
    showBenchmark,
    approximation: payload.meta.approximation,
    theme,
  }

  const axisBase = {
    type: 'category' as const,
    data: dates,
    boundaryGap: true,
    axisLine: { lineStyle: { color: theme.line } },
    axisTick: { show: false },
    splitLine: { show: false },
  }
  const valueAxisBase = {
    type: 'value' as const,
    axisLine: { show: false },
    axisTick: { show: false },
    axisLabel: { color: theme.inkSubtle },
    splitLine: { lineStyle: { color: theme.line } },
  }

  const series: NonNullable<EChartsOption['series']> = [
    {
      name: PORTFOLIO_SERIES,
      type: 'candlestick',
      xAxisIndex: 0,
      yAxisIndex: 0,
      data: toCandlestickData(payload.candles),
      itemStyle: {
        color: theme.up,
        color0: theme.down,
        borderColor: theme.up,
        borderColor0: theme.down,
      },
    },
    {
      name: FLOW_SERIES,
      type: 'bar',
      xAxisIndex: 1,
      yAxisIndex: 1,
      barMaxWidth: 12,
      data: buildFlowSeriesData(dates, payload.flows, theme),
      markLine: {
        silent: true,
        symbol: 'none',
        label: { show: false },
        lineStyle: { color: theme.lineStrong, width: 1, type: 'solid' },
        data: [{ yAxis: 0 }],
      },
    },
    {
      name: DRAWDOWN_SERIES,
      type: 'line',
      xAxisIndex: 2,
      yAxisIndex: 2,
      data: alignDrawdown(dates, payload.drawdown),
      showSymbol: false,
      connectNulls: true,
      lineStyle: { width: 1.5, color: theme.down },
      itemStyle: { color: theme.down },
      areaStyle: { color: theme.down, opacity: 0.12 },
    },
  ]

  if (hasBenchmarkLine && payload.benchmark) {
    series.splice(1, 0, {
      name: benchmarkSeriesName(payload.benchmark),
      type: 'line',
      xAxisIndex: 0,
      yAxisIndex: 0,
      z: 3,
      data: alignBenchmark(dates, payload.benchmark),
      showSymbol: false,
      connectNulls: false,
      lineStyle: { width: 2, color: theme.accent },
      itemStyle: { color: theme.accent },
    })
  }

  return {
    animation: false,
    backgroundColor: 'transparent',
    textStyle: { color: theme.ink },
    /*
     * PANE TITLES ARE BASIS-DEPENDENT, and both changes are corrections rather than
     * cosmetics:
     *
     *  - grid 0 plots holdings only in BOTH bases, but on the cash basis "Portfolio
     *    value" would now be a different number from what the tiles call total value.
     *    "Holdings value" is precise. On the trade basis holdings ARE the portfolio
     *    value, so the old title is still exactly right and is kept — which is also
     *    what keeps an untracked payload byte-identical.
     *  - grid 1 carries ONLY deposits and withdrawals on the cash basis (trades are
     *    an internal transfer under a full cash account and are absent from `flows`),
     *    so leaving it labelled "Net cash flow" would have the pane lying about what
     *    the bars are.
     */
    title: [
      {
        text: tracksCash ? 'Holdings value' : 'Portfolio value',
        top: '2%',
        left: '1.5%',
        textStyle: paneTitle(theme),
      },
      {
        text: tracksCash ? 'Deposits & withdrawals' : 'Net cash flow',
        top: '64%',
        left: '1.5%',
        textStyle: paneTitle(theme),
      },
      { text: 'Drawdown from peak', top: '80.5%', left: '1.5%', textStyle: paneTitle(theme) },
    ],
    legend: hasBenchmarkLine
      ? {
          top: '2%',
          right: '2%',
          textStyle: { color: theme.inkMuted },
          data: [PORTFOLIO_SERIES, payload.benchmark ? benchmarkSeriesName(payload.benchmark) : ''],
        }
      : undefined,
    grid: GRIDS.map((g) => ({ ...g })),
    axisPointer: {
      link: [{ xAxisIndex: 'all' }],
      label: { backgroundColor: theme.inkMuted },
    },
    tooltip: {
      trigger: 'axis',
      axisPointer: { type: 'cross' },
      backgroundColor: theme.panel,
      borderColor: theme.line,
      textStyle: { color: theme.ink },
      formatter: (params: unknown): string => renderTooltip(params, ctx),
    },
    xAxis: [
      { ...axisBase, gridIndex: 0, axisLabel: { show: false } },
      { ...axisBase, gridIndex: 1, axisLabel: { show: false } },
      {
        ...axisBase,
        gridIndex: 2,
        axisLabel: { show: true, color: theme.inkSubtle, formatter: (v: string) => formatDate(v) },
      },
    ],
    yAxis: [
      { ...valueAxisBase, gridIndex: 0, scale: true, axisLabel: { color: theme.inkSubtle, formatter: formatCompactCurrency } },
      { ...valueAxisBase, gridIndex: 1, scale: true, axisLabel: { color: theme.inkSubtle, formatter: formatCompactCurrency } },
      { ...valueAxisBase, gridIndex: 2, max: 0, axisLabel: { color: theme.inkSubtle, formatter: percentAxis } },
    ],
    dataZoom: [
      { type: 'inside', xAxisIndex: [0, 1, 2] },
      {
        type: 'slider',
        xAxisIndex: [0, 1, 2],
        bottom: '1%',
        height: 16,
        borderColor: theme.line,
        fillerColor: 'transparent',
        dataBackground: { lineStyle: { color: theme.lineStrong }, areaStyle: { color: theme.panelHi } },
        textStyle: { color: theme.inkSubtle },
      },
    ],
    series,
  }
}

function paneTitle(theme: ChartTheme) {
  return { color: theme.inkMuted, fontSize: 12, fontWeight: 500 as const }
}
