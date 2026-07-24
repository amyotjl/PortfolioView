import { describe, expect, it } from 'vitest'
import {
  buildDashboardChartOption,
  toCandlestickData,
  alignBenchmark,
  buildFlowSeriesData,
  alignDrawdown,
  extractDates,
} from './candles'
import { LIGHT_CHART_THEME as theme } from './theme'
import type { CandlesResponse } from '@/types'

const APPROX = 'Portfolio H/L are bounds; component extremes may not co-occur.'

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
  },
}

const EMPTY: CandlesResponse = {
  candles: [],
  benchmark: null,
  flows: [],
  drawdown: [],
  meta: { partial: false, filled_dates: [], benchmark_clamped: false, approximation: '' },
}

interface OptShape {
  grid: unknown[]
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
