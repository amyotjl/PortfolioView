import { describe, expect, it } from 'vitest'
import {
  buildContributionGrowthOption,
  deriveContributions,
  floorSeries,
  gainSeries,
  shortfallSeries,
  signedCents,
  valueSeries,
  CAPITAL_SERIES,
  GAIN_SERIES,
  SHORTFALL_SERIES,
  VALUE_SERIES,
} from './contributions'
import { LIGHT_CHART_THEME as theme } from './theme'
import type { CandlesResponse, Candle, Flow } from '@/types'

/**
 * ONE hand-computed fixture, worked out in cents below, that exercises every
 * branch of the derivation: days before any flow, a contribution, a withdrawal,
 * a day whose growth is NEGATIVE (the shortfall band), and a recovery.
 *
 *   base = the first candle's OPEN = 1000.00 -> 100000c
 *
 *   date        close    flow      contributed        value    growth
 *   2026-01-05  1050.00  —         100000             105000    +5000
 *   2026-01-06  1030.00  —         100000             103000    +3000
 *   2026-01-07  1530.00  +500.00   100000+50000=150000 153000   +3000
 *   2026-01-08  1350.00  -100.00   150000-10000=140000 135000   -5000  <- under water
 *   2026-01-09  1450.00  —         140000             145000    +5000
 */
function candle(t: string, o: string, c: string): Candle {
  return { t, o, c, h: c, l: o }
}

function flow(t: string, net: string): Flow {
  return { t, net, items: [] }
}

const CANDLES: Candle[] = [
  candle('2026-01-05', '1000.00', '1050.00'),
  candle('2026-01-06', '1050.00', '1030.00'),
  candle('2026-01-07', '1030.00', '1530.00'),
  candle('2026-01-08', '1530.00', '1350.00'),
  candle('2026-01-09', '1350.00', '1450.00'),
]

function payload(overrides: Partial<CandlesResponse> = {}): CandlesResponse {
  return {
    candles: CANDLES,
    benchmark: null,
    flows: [flow('2026-01-07', '500.00'), flow('2026-01-08', '-100.00')],
    drawdown: [],
    meta: { partial: false, filled_dates: [], benchmark_clamped: false, approximation: '' },
    ...overrides,
  }
}

describe('deriveContributions', () => {
  it('matches the hand-computed cents for every day', () => {
    const { baseCents, points } = deriveContributions(payload())

    expect(baseCents).toBe(100_000)
    expect(points).toEqual([
      { t: '2026-01-05', valueCents: 105_000, contributedCents: 100_000, growthCents: 5_000 },
      { t: '2026-01-06', valueCents: 103_000, contributedCents: 100_000, growthCents: 3_000 },
      { t: '2026-01-07', valueCents: 153_000, contributedCents: 150_000, growthCents: 3_000 },
      { t: '2026-01-08', valueCents: 135_000, contributedCents: 140_000, growthCents: -5_000 },
      { t: '2026-01-09', valueCents: 145_000, contributedCents: 140_000, growthCents: 5_000 },
    ])
  })

  it('starts the baseline at the window OPENING value, not at zero', () => {
    // The whole point of the window baseline: a range that starts mid-life must
    // not present its partial flow history as if it were lifetime contributions.
    const { points } = deriveContributions(payload())
    expect(points[0].contributedCents).toBe(100_000)
    // Day one's growth is exactly day one's mark-to-market move (close - open).
    expect(points[0].growthCents).toBe(105_000 - 100_000)
  })

  it('does NOT re-add a flow the opening value already contains', () => {
    // REGRESSION (found by looking at the rendered chart, not by a fixture): a
    // candle's `o` is that date's END-OF-DAY shares at the day's opening price
    // (Portfolios::Valuation), so it already reflects trades dated on or before
    // the first candle. Adding day one's flow on top double-counts the purchase
    // and paints a shortfall band that is not in the data.
    const { baseCents, points } = deriveContributions(
      payload({ flows: [flow('2026-01-05', '900.00'), flow('2026-01-07', '500.00')] }),
    )

    expect(baseCents).toBe(100_000)
    expect(points[0].contributedCents).toBe(100_000) // NOT 190_000
    expect(points[0].growthCents).toBe(5_000) // a gain, not a phantom shortfall
    // The later flow still lands normally.
    expect(points[2].contributedCents).toBe(150_000)
  })

  it('discards a flow dated BEFORE the window as well — also already in the open', () => {
    const { points } = deriveContributions(
      payload({ flows: [flow('2025-12-30', '5000.00')] }),
    )
    expect(points.map((p) => p.contributedCents)).toEqual([
      100_000, 100_000, 100_000, 100_000, 100_000,
    ])
  })

  it('accrues a flow dated between two candles at the NEXT candle', () => {
    // A flow whose date is not itself a candle date (e.g. the payload's range
    // edge) must still be counted exactly once rather than dropped.
    const { points } = deriveContributions(
      payload({ flows: [flow('2026-01-06', '200.00'), flow('2026-01-06', '300.00')] }),
    )
    expect(points[0].contributedCents).toBe(100_000)
    expect(points[1].contributedCents).toBe(150_000)
    expect(points[4].contributedCents).toBe(150_000)
  })

  it('is order-independent — flows are accumulated by date, not by array index', () => {
    const forward = deriveContributions(payload())
    const reversed = deriveContributions(
      payload({ flows: [flow('2026-01-08', '-100.00'), flow('2026-01-07', '500.00')] }),
    )
    expect(reversed.points).toEqual(forward.points)
  })

  it('treats unparseable money as a zero delta instead of poisoning the sum', () => {
    const { points } = deriveContributions(payload({ flows: [flow('2026-01-07', 'n/a')] }))
    expect(points.map((p) => p.contributedCents)).toEqual([
      100_000, 100_000, 100_000, 100_000, 100_000,
    ])
  })

  it('yields no points and a zero base on an empty payload', () => {
    expect(deriveContributions(payload({ candles: [], flows: [] }))).toEqual({
      baseCents: 0,
      points: [],
    })
  })
})

describe('band series', () => {
  const { points } = deriveContributions(payload())

  it('clips the capital band at the total value and completes it with a shortfall', () => {
    expect(floorSeries(points)).toEqual([1000, 1000, 1500, 1350, 1400])
    expect(gainSeries(points)).toEqual([50, 30, 30, 0, 50])
    expect(shortfallSeries(points)).toEqual([0, 0, 0, 50, 0])
    expect(valueSeries(points)).toEqual([1050, 1030, 1530, 1350, 1450])
  })

  it('never shows both growth bands on the same day', () => {
    const gains = gainSeries(points)
    const shortfalls = shortfallSeries(points)
    gains.forEach((gain, i) => expect(gain === 0 || shortfalls[i] === 0).toBe(true))
  })

  it('stacks to max(contributed, value) so the value line is always a real edge', () => {
    const floors = floorSeries(points)
    const gains = gainSeries(points)
    const shortfalls = shortfallSeries(points)
    points.forEach((p, i) => {
      const stackTop = floors[i] + gains[i] + shortfalls[i]
      expect(stackTop).toBeCloseTo(Math.max(p.contributedCents, p.valueCents) / 100, 10)
    })
  })
})

describe('signedCents', () => {
  it('signs a gain, keeps a loss negative, and leaves zero unsigned', () => {
    expect(signedCents(5_000)).toBe('+$50.00')
    expect(signedCents(-5_000)).toBe('-$50.00')
    expect(signedCents(0)).toBe('$0.00')
  })
})

interface OptionShape {
  legend: { data: string[] }
  xAxis: { data: string[] }
  series: Array<{
    name: string
    type: string
    stack?: string
    data: number[]
    lineStyle?: { color?: string; width?: number }
    areaStyle?: { color?: string }
    itemStyle?: { color?: string }
  }>
  tooltip: { formatter: (p: unknown) => string }
}

function build(p: CandlesResponse = payload()): OptionShape {
  return buildContributionGrowthOption(
    deriveContributions(p),
    theme,
  ) as unknown as OptionShape
}

describe('buildContributionGrowthOption', () => {
  it('stacks the three bands together and leaves the value line unstacked', () => {
    const option = build()
    const byName = new Map(option.series.map((s) => [s.name, s]))

    expect(byName.get(CAPITAL_SERIES)?.stack).toBe('contribution')
    expect(byName.get(GAIN_SERIES)?.stack).toBe('contribution')
    expect(byName.get(SHORTFALL_SERIES)?.stack).toBe('contribution')
    expect(byName.get(VALUE_SERIES)?.stack).toBeUndefined()
    expect(byName.get(VALUE_SERIES)?.data).toEqual([1050, 1030, 1530, 1350, 1450])
  })

  it('paints capital with the identity token and growth with the polarity tokens', () => {
    const byName = new Map(build().series.map((s) => [s.name, s]))
    expect(byName.get(CAPITAL_SERIES)?.areaStyle?.color).toBe(theme.capital)
    expect(byName.get(GAIN_SERIES)?.areaStyle?.color).toBe(theme.up)
    expect(byName.get(SHORTFALL_SERIES)?.areaStyle?.color).toBe(theme.down)
  })

  it('gives every band an itemStyle so the LEGEND marker matches its fill', () => {
    // REGRESSION: ECharts draws legend markers from itemStyle, not areaStyle. With
    // itemStyle unset it substituted its own default palette and the swatches came
    // out blue/green/yellow — mislabelling the very bands they identify.
    const byName = new Map(build().series.map((s) => [s.name, s]))
    for (const name of [CAPITAL_SERIES, GAIN_SERIES, SHORTFALL_SERIES]) {
      const series = byName.get(name)
      expect(series?.itemStyle?.color, name).toBe(series?.areaStyle?.color)
    }
    expect(byName.get(VALUE_SERIES)?.itemStyle?.color).toBe(theme.ink)
  })

  it('draws each band edge in the SURFACE color — the 2px gap between fills', () => {
    // Regression guard: a saturated band edge would read as a border around the
    // fills instead of a gap between them.
    for (const name of [CAPITAL_SERIES, GAIN_SERIES, SHORTFALL_SERIES]) {
      const band = build().series.find((s) => s.name === name)
      expect(band?.lineStyle).toMatchObject({ color: theme.panel, width: 2 })
    }
  })

  it('always carries a legend so identity is never color-alone', () => {
    expect(build().legend.data).toEqual([
      CAPITAL_SERIES,
      GAIN_SERIES,
      SHORTFALL_SERIES,
      VALUE_SERIES,
    ])
  })

  it('uses the ISO dates directly as category values', () => {
    expect(build().xAxis.data).toEqual([
      '2026-01-05',
      '2026-01-06',
      '2026-01-07',
      '2026-01-08',
      '2026-01-09',
    ])
  })

  it('builds a valid empty option for a zero-transaction portfolio', () => {
    const option = build(payload({ candles: [], flows: [] }))
    expect(option.xAxis.data).toEqual([])
    expect(option.series.every((s) => s.data.length === 0)).toBe(true)
  })

  describe('tooltip', () => {
    const render = (date: string): string => build().tooltip.formatter([{ axisValue: date }])

    it('labels a positive day "Growth" with a signed figure', () => {
      const html = render('2026-01-07')
      expect(html).toContain(GAIN_SERIES)
      expect(html).toContain('+$30.00')
      expect(html).toContain('$1,530.00') // total value
      expect(html).toContain('$1,500.00') // contributed capital
      expect(html).not.toContain(SHORTFALL_SERIES)
    })

    it('labels an under-water day "Below contributions" with a negative figure', () => {
      const html = render('2026-01-08')
      expect(html).toContain(SHORTFALL_SERIES)
      expect(html).toContain('-$50.00')
      expect(html).not.toContain(GAIN_SERIES)
    })

    it('returns empty for a date with no point, and for a non-date axis value', () => {
      expect(render('2026-02-01')).toBe('')
      expect(build().tooltip.formatter([{ axisValue: 42 }])).toBe('')
    })
  })
})
