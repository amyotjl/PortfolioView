import { describe, expect, it } from 'vitest'
import {
  buildDashboardChartOption,
  toCandlestickData,
  alignBenchmark,
  buildFlowSeriesData,
  alignDrawdown,
  extractDates,
  flowKindLabel,
} from './candles'
import { LIGHT_CHART_THEME as theme } from './theme'
import type { CandlesResponse } from '@/types'

const APPROX = 'Portfolio H/L are bounds; component extremes may not co-occur.'

/**
 * The TRADE-BASIS fixture: `cash: null`, `flow_basis: 'trades'`. Every expectation
 * written against it also serves as the #80 no-regression pin — an untracked payload
 * must produce exactly the output it did before cash existed.
 */
const fixture: CandlesResponse = {
  candles: [
    { t: '2026-01-02', o: '100.00', h: '110.00', l: '95.00', c: '105.00' },
    { t: '2026-01-05', o: '105.00', h: '112.00', l: '104.00', c: '108.00' },
    { t: '2026-01-06', o: '108.00', h: '109.00', l: '101.00', c: '102.00' },
  ],
  benchmark: {
    symbol: 'SPY',
    // Starts on 01-05 — does not cover 01-02 (short-history clamp).
    values: [
      { t: '2026-01-05', v: '500.00' },
      { t: '2026-01-06', v: '498.00' },
    ],
  },
  cash: null,
  flows: [
    { t: '2026-01-02', net: '1000.00', items: [{ ticker: 'AAPL', kind: 'buy', amount: '1000.00' }] },
    { t: '2026-01-06', net: '-250.00', items: [{ ticker: 'AAPL', kind: 'sell', amount: '-250.00' }] },
  ],
  drawdown: [
    { t: '2026-01-02', v: '0.00000000' },
    { t: '2026-01-05', v: '-0.02000000' },
    { t: '2026-01-06', v: '-0.08340000' },
  ],
  meta: {
    partial: false,
    filled_dates: ['2026-01-06'],
    benchmark_clamped: true,
    approximation: APPROX,
    flow_basis: 'trades',
    cash_negative: false,
    cash_negative_since: null,
  },
}

/**
 * The same three days for a portfolio that RECORDS CASH. Holdings legs are identical
 * (candles are holdings-only in both bases); cash is a separate end-of-day series, and
 * `flows` carries deposits/withdrawals only — no trade items at all.
 */
const CASH_FIXTURE: CandlesResponse = {
  ...fixture,
  cash: [
    { t: '2026-01-02', v: '900.00' },
    { t: '2026-01-05', v: '900.00' },
    { t: '2026-01-06', v: '-50.00' },
  ],
  flows: [
    {
      t: '2026-01-02',
      net: '1000.00',
      items: [{ ticker: null, kind: 'deposit', amount: '1000.00' }],
    },
    {
      t: '2026-01-06',
      net: '-250.00',
      items: [{ ticker: null, kind: 'withdrawal', amount: '-250.00' }],
    },
  ],
  meta: { ...fixture.meta, flow_basis: 'cash', cash_negative: true, cash_negative_since: '2026-01-06' },
}

const EMPTY: CandlesResponse = {
  candles: [],
  benchmark: null,
  cash: null,
  flows: [],
  drawdown: [],
  meta: {
    partial: false,
    filled_dates: [],
    benchmark_clamped: false,
    approximation: '',
    flow_basis: 'trades',
    cash_negative: false,
    cash_negative_since: null,
  },
}

interface OptShape {
  grid: unknown[]
  title: Array<{ text?: string }>
  series: Array<{
    name?: string
    type?: string
    xAxisIndex?: number
    yAxisIndex?: number
    data?: unknown[]
    areaStyle?: unknown
  }>
  dataZoom: Array<{ xAxisIndex?: number[] }>
  axisPointer: { link?: unknown }
  xAxis: Array<{ type?: string; data?: unknown[] }>
  yAxis: Array<{ max?: number }>
  legend?: unknown
  tooltip: { formatter: (p: unknown) => string }
}

function build(showBenchmark: boolean, payload = fixture): OptShape {
  return buildDashboardChartOption(payload, theme, { showBenchmark }) as unknown as OptShape
}

function seriesNamed(opt: OptShape, name: string) {
  return opt.series.find((s) => s.name === name)
}

describe('candle series mapping', () => {
  it('maps o/h/l/c to ECharts [open, close, low, high] order', () => {
    expect(toCandlestickData(fixture.candles)).toEqual([
      [100, 105, 95, 110],
      [105, 108, 104, 112],
      [108, 102, 101, 109],
    ])
  })

  it('uses the ISO date strings directly as the shared category axis', () => {
    expect(extractDates(fixture.candles)).toEqual(['2026-01-02', '2026-01-05', '2026-01-06'])
  })
})

describe('benchmark line join', () => {
  it('aligns benchmark values onto the candle dates, null where not covered', () => {
    const dates = extractDates(fixture.candles)
    expect(alignBenchmark(dates, fixture.benchmark)).toEqual([null, 500, 498])
  })

  it('returns all-null when there is no benchmark', () => {
    expect(alignBenchmark(['2026-01-02', '2026-01-05'], null)).toEqual([null, null])
  })
})

describe('flows sign coloring', () => {
  it('colors a positive net contribution with the up token and a withdrawal with down', () => {
    const dates = extractDates(fixture.candles)
    const data = buildFlowSeriesData(dates, fixture.flows, theme)
    expect(data[0]).toEqual({ value: 1000, itemStyle: { color: theme.up } })
    expect(data[1]).toBeNull() // no flow on 2026-01-05
    expect(data[2]).toEqual({ value: -250, itemStyle: { color: theme.down } })
  })
})

describe('drawdown area', () => {
  it('aligns drawdown fractions onto the date axis', () => {
    const dates = extractDates(fixture.candles)
    expect(alignDrawdown(dates, fixture.drawdown)).toEqual([0, -0.02, -0.0834])
  })

  it('renders the drawdown series as an area on the third grid, capped at 0', () => {
    const opt = build(false)
    const drawdown = seriesNamed(opt, 'Drawdown')
    expect(drawdown?.type).toBe('line')
    expect(drawdown?.xAxisIndex).toBe(2)
    expect(drawdown?.yAxisIndex).toBe(2)
    expect(drawdown?.areaStyle).toBeTruthy()
    expect(opt.yAxis[2].max).toBe(0)
  })
})

describe('grid linkage', () => {
  it('builds three grids with a shared crosshair and a shared dataZoom', () => {
    const opt = build(true)
    expect(opt.grid).toHaveLength(3)
    expect(opt.xAxis).toHaveLength(3)
    expect(opt.yAxis).toHaveLength(3)
    expect(opt.axisPointer.link).toEqual([{ xAxisIndex: 'all' }])
    for (const zoom of opt.dataZoom) {
      expect(zoom.xAxisIndex).toEqual([0, 1, 2])
    }
  })

  it('places the candlestick, flow bar and drawdown on grids 0/1/2', () => {
    const opt = build(false)
    expect(seriesNamed(opt, 'Portfolio')?.type).toBe('candlestick')
    expect(seriesNamed(opt, 'Portfolio')?.xAxisIndex).toBe(0)
    expect(seriesNamed(opt, 'Net cash flow')?.type).toBe('bar')
    expect(seriesNamed(opt, 'Net cash flow')?.xAxisIndex).toBe(1)
    expect(seriesNamed(opt, 'Drawdown')?.xAxisIndex).toBe(2)
  })
})

describe('benchmark presence by flag', () => {
  it('adds the benchmark line + legend when enabled and data is present', () => {
    const opt = build(true)
    const line = seriesNamed(opt, 'Benchmark · SPY')
    expect(line?.type).toBe('line')
    expect(line?.xAxisIndex).toBe(0)
    expect(opt.legend).toBeTruthy()
  })

  it('omits the benchmark line + legend when the flag is off', () => {
    const opt = build(false)
    expect(seriesNamed(opt, 'Benchmark · SPY')).toBeUndefined()
    expect(opt.legend).toBeUndefined()
  })

  it('omits the benchmark line when the payload has no benchmark, even if enabled', () => {
    const opt = build(true, { ...fixture, benchmark: null })
    expect(seriesNamed(opt, 'Benchmark · SPY')).toBeUndefined()
    expect(opt.legend).toBeUndefined()
  })
})

describe('axis tooltip', () => {
  it('includes the H/L-bounds disclaimer whenever meta.approximation is set', () => {
    const html = build(true).tooltip.formatter([{ axisValue: '2026-01-05' }])
    expect(html).toContain(APPROX)
  })

  it('omits the disclaimer when meta.approximation is empty', () => {
    const opt = build(true, { ...fixture, meta: { ...fixture.meta, approximation: '' } })
    expect(opt.tooltip.formatter([{ axisValue: '2026-01-05' }])).not.toContain(APPROX)
  })

  it('flags a forward-filled date (meta.filled_dates)', () => {
    const formatter = build(true).tooltip.formatter
    expect(formatter([{ axisValue: '2026-01-06' }])).toContain('forward-filled')
    expect(formatter([{ axisValue: '2026-01-05' }])).not.toContain('forward-filled')
  })

  it('shows the benchmark row only when the benchmark is enabled', () => {
    expect(build(true).tooltip.formatter([{ axisValue: '2026-01-05' }])).toContain('Benchmark · SPY')
    expect(build(false).tooltip.formatter([{ axisValue: '2026-01-05' }])).not.toContain(
      'Benchmark · SPY',
    )
  })

  it('lists per-day flow items with a signed amount', () => {
    const html = build(true).tooltip.formatter([{ axisValue: '2026-01-02' }])
    expect(html).toContain('AAPL')
    expect(html).toContain('+$1,000.00')
  })
})

describe('empty payload', () => {
  it('produces a valid, empty option without throwing', () => {
    const opt = build(false, EMPTY)
    expect(opt.grid).toHaveLength(3)
    expect(seriesNamed(opt, 'Portfolio')?.data).toEqual([])
    expect(opt.xAxis[0].data).toEqual([])
  })
})

// --- Cash (#80) --------------------------------------------------------------

describe('flowKindLabel', () => {
  it('labels the cash kinds', () => {
    expect(flowKindLabel('deposit')).toBe('Deposit')
    expect(flowKindLabel('withdrawal')).toBe('Withdrawal')
    expect(flowKindLabel('dividend_cash')).toBe('Cash dividend')
  })

  it('passes buy/sell through verbatim, which is what keeps a trade tooltip identical', () => {
    expect(flowKindLabel('buy')).toBe('buy')
    expect(flowKindLabel('sell')).toBe('sell')
  })

  it('falls through to the RAW STRING for an unknown kind', () => {
    // `kind` is z.string() precisely so a newer backend kind renders ugly instead of
    // throwing. The bars color by the sign of `amount`, never by `kind`, so an unknown
    // kind cannot break the chart either.
    expect(flowKindLabel('rebate')).toBe('rebate')
  })
})

describe('pane titles follow the basis', () => {
  it('keeps "Portfolio value" and "Net cash flow" when cash is null', () => {
    // The no-regression pin: on the trade basis holdings ARE the portfolio value and
    // the flow bars ARE net cash flow, so both old titles are still exactly right.
    const titles = build(true).title.map((t) => t.text)
    expect(titles).toEqual(['Portfolio value', 'Net cash flow', 'Drawdown from peak'])
  })

  it('retitles to "Holdings value" and "Deposits & withdrawals" when cash is tracked', () => {
    // Both are corrections, not cosmetics: grid 0 is now a different number from the
    // Total value tile, and grid 1 no longer contains trades at all.
    const titles = build(true, CASH_FIXTURE).title.map((t) => t.text)
    expect(titles).toEqual(['Holdings value', 'Deposits & withdrawals', 'Drawdown from peak'])
  })

  it('discriminates on payload.cash, not on meta.flow_basis', () => {
    // A pure builder must read the series it is drawing. If the two ever disagreed,
    // the presence of the data wins over the label claiming it.
    const mislabelled: CandlesResponse = {
      ...fixture,
      meta: { ...fixture.meta, flow_basis: 'cash' },
    }
    expect(build(true, mislabelled).title[0].text).toBe('Portfolio value')
  })
})

describe('tooltip cash rows', () => {
  const render = (payload: CandlesResponse, date: string): string =>
    build(true, payload).tooltip.formatter([{ axisValue: date }])

  it('shows Close and no Total/Cash rows when cash is null', () => {
    const html = render(fixture, '2026-01-05')
    expect(html).toContain('Close')
    expect(html).not.toContain('>Total<')
    expect(html).not.toContain('>Cash<')
    expect(html).not.toContain('>Holdings<')
  })

  it('adds Total and Cash rows, and relabels Close to Holdings, when cash is tracked', () => {
    const html = render(CASH_FIXTURE, '2026-01-05')
    // Holdings close $108.00 + cash $900.00 = $1,008.00, summed in exact cents.
    expect(html).toContain('$1,008.00')
    expect(html).toContain('Total')
    expect(html).toContain('Holdings')
    expect(html).toContain('$900.00')
    expect(html).toContain('Cash')
    expect(html).not.toContain('Close')
  })

  it('keeps the O/H/L subline, which is still holdings-only in both bases', () => {
    expect(render(CASH_FIXTURE, '2026-01-05')).toContain('Open $105.00')
  })

  it('paints a negative cash row with the warn token, never the loss token', () => {
    // Negative cash is a bookkeeping gap, not a loss — up/down stay reserved for real
    // gain/loss polarity.
    const html = render(CASH_FIXTURE, '2026-01-06')
    expect(html).toContain('-$50.00')
    expect(html).toContain(theme.warn)
  })

  it('uses no warn token at all when cash is positive', () => {
    expect(render(CASH_FIXTURE, '2026-01-05')).not.toContain(theme.warn)
  })

  it('still carries the H/L bounds disclaimer on the cash basis', () => {
    expect(render(CASH_FIXTURE, '2026-01-05')).toContain(APPROX)
  })
})

describe('tooltip flow items', () => {
  const render = (payload: CandlesResponse, date: string): string =>
    build(true, payload).tooltip.formatter([{ axisValue: date }])

  it('renders a trade item as `TICKER kind ±$x` — unchanged', () => {
    const html = render(fixture, '2026-01-02')
    expect(html).toContain('AAPL buy +$1,000.00')
  })

  it('renders a cash item with a LABEL and no ticker token', () => {
    // `ticker` is null for a deposit; the leading token is dropped rather than
    // rendered as the string "null".
    const html = render(CASH_FIXTURE, '2026-01-02')
    expect(html).toContain('Deposit +$1,000.00')
    expect(html).not.toContain('null')
  })

  it('renders a withdrawal item with its negative amount', () => {
    expect(render(CASH_FIXTURE, '2026-01-06')).toContain('Withdrawal -$250.00')
  })

  it('renders an unrecognised kind verbatim rather than blanking the line', () => {
    const odd: CandlesResponse = {
      ...CASH_FIXTURE,
      flows: [
        { t: '2026-01-02', net: '5.00', items: [{ ticker: null, kind: 'rebate', amount: '5.00' }] },
      ],
    }
    expect(render(odd, '2026-01-02')).toContain('rebate +$5.00')
  })
})

describe('cash adds no series to grid 0', () => {
  it('draws exactly the same series set in both bases', () => {
    // Cash goes in neither the candle nor a fourth series: the candlestick's grammar
    // says "this is a market move", so a deposit drawn as a tall green candle would be
    // a lie about performance, and cash has no O/H/L to fold in.
    const names = (payload: CandlesResponse) => build(true, payload).series.map((s) => s.name)
    expect(names(CASH_FIXTURE)).toEqual(names(fixture))
  })

  it('leaves the candlestick data holdings-only when cash is tracked', () => {
    const opt = build(false, CASH_FIXTURE)
    expect(seriesNamed(opt, 'Portfolio')?.data).toEqual(toCandlestickData(fixture.candles))
  })
})
