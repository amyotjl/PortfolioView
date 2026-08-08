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
import type { CandlesResponse, CashPoint, Candle, Flow } from '@/types'

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

function cash(t: string, v: string): CashPoint {
  return { t, v }
}

/**
 * The TRADE-BASIS payload: `cash: null`. Every expectation below written against it
 * doubles as the #80 no-regression pin — with cash untracked the derivation must
 * produce byte-identical output to before the feature.
 */
function payload(overrides: Partial<CandlesResponse> = {}): CandlesResponse {
  return {
    candles: CANDLES,
    benchmark: null,
    cash: null,
    flows: [flow('2026-01-07', '500.00'), flow('2026-01-08', '-100.00')],
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

// --- Cash (#80) --------------------------------------------------------------

describe('cash-aware derivation', () => {
  /**
   * THE WORKED EXAMPLE from issue #80, in full. Day 4 is the payoff — a trade becomes
   * VALUE-NEUTRAL, which the pre-cash chart structurally could not express — and day 3
   * is the other one: idle cash is now *in* the value line instead of silently omitted.
   *
   *   day | holdings |   cash | value  | contributed | growth
   *     1 |    9,000 |  1,000 | 10,000 | 10,000 (base) |     0   deposit 10k, buy 9k
   *     2 |    9,900 |  1,000 | 10,900 | 10,000        |  +900   +10%
   *     3 |    9,900 |  6,000 | 15,900 | 15,000        |  +900   deposit 5k
   *     4 |   15,900 |      0 | 15,900 | 15,000        |  +900   buy 6k  <- value-neutral
   *     5 |   15,900 | -2,000 | 13,900 | 13,000        |  +900   withdraw 2k
   *
   * Growth is +900 on every day from 2 onward, which is the point: after the first day's
   * market move, NOTHING the user did to their cash changed the growth figure.
   */
  const WORKED: CandlesResponse = payload({
    candles: [
      candle('2026-03-02', '9000.00', '9000.00'),
      candle('2026-03-03', '9000.00', '9900.00'),
      candle('2026-03-04', '9900.00', '9900.00'),
      candle('2026-03-05', '9900.00', '15900.00'),
      candle('2026-03-06', '15900.00', '15900.00'),
    ],
    cash: [
      cash('2026-03-02', '1000.00'),
      cash('2026-03-03', '1000.00'),
      cash('2026-03-04', '6000.00'),
      cash('2026-03-05', '0.00'),
      cash('2026-03-06', '-2000.00'),
    ],
    // EXCLUSIVE flows: deposits and withdrawals only. The two buys are absent — under a
    // full cash account a trade is an internal transfer that does not move total value.
    flows: [
      flow('2026-03-02', '10000.00'),
      flow('2026-03-04', '5000.00'),
      flow('2026-03-06', '-2000.00'),
    ],
  })

  it('reproduces the worked example exactly, day by day', () => {
    const { baseCents, points } = deriveContributions(WORKED)

    // Base is the window-opening TOTAL: holdings at the open plus that day's cash.
    expect(baseCents).toBe(1_000_000)
    expect(points).toEqual([
      { t: '2026-03-02', valueCents: 1_000_000, contributedCents: 1_000_000, growthCents: 0 },
      { t: '2026-03-03', valueCents: 1_090_000, contributedCents: 1_000_000, growthCents: 90_000 },
      { t: '2026-03-04', valueCents: 1_590_000, contributedCents: 1_500_000, growthCents: 90_000 },
      { t: '2026-03-05', valueCents: 1_590_000, contributedCents: 1_500_000, growthCents: 90_000 },
      { t: '2026-03-06', valueCents: 1_390_000, contributedCents: 1_300_000, growthCents: 90_000 },
    ])
  })

  it('makes a trade value-neutral: day 4 buys $6k and NOTHING moves', () => {
    const { points } = deriveContributions(WORKED)
    const [, , day3, day4] = points
    expect(day4.valueCents).toBe(day3.valueCents)
    expect(day4.contributedCents).toBe(day3.contributedCents)
    expect(day4.growthCents).toBe(day3.growthCents)
  })

  it('counts idle cash in the value line: day 3 deposits $5k and value rises by it', () => {
    const { points } = deriveContributions(WORKED)
    expect(points[2].valueCents - points[1].valueCents).toBe(500_000)
    // ...and it is a CONTRIBUTION, not growth.
    expect(points[2].growthCents).toBe(points[1].growthCents)
  })

  it('handles a negative balance without corrupting the bands', () => {
    const { points } = deriveContributions(WORKED)
    const day5 = points[4]
    expect(day5.valueCents).toBe(1_390_000)
    // Still above contributions, so the capital band clips at contributed and the gain
    // band completes it — no shortfall.
    expect(shortfallSeries([day5])).toEqual([0])
    expect(gainSeries([day5])).toEqual([900])
    expect(floorSeries([day5])).toEqual([13_000])
  })

  /**
   * THE FIXTURE PAIR — the only construction that discriminates the end-of-day
   * convention, and the reason it exists: #52 shipped a phantom band whose SINGLE
   * fixture *confirmed* the bug instead of catching it.
   *
   * Both portfolios make the same $10,000 deposit and the same $9,000 buy. The only
   * difference is WHICH DAY: on day one (inside the window baseline) or on day two
   * (after it). The discard rule `flows.filter(f => f.t > first.t)` must handle them
   * differently and arrive at the same answer — growth 0 on the deposit day, because
   * depositing money is not a gain.
   *
   * A START-of-day cash series breaks the day-one case only: `cash(day1)` would be 0,
   * so the base would be $9,000 while value is $10,000, inventing $1,000 of phantom
   * growth on day one. The day-two case would still pass. Hence the pair.
   */
  describe('the end-of-day convention, as a fixture PAIR', () => {
    const DEPOSIT_ON_DAY_ONE: CandlesResponse = payload({
      candles: [
        candle('2026-04-01', '9000.00', '9000.00'),
        candle('2026-04-02', '9000.00', '9900.00'),
      ],
      cash: [cash('2026-04-01', '1000.00'), cash('2026-04-02', '1000.00')],
      flows: [flow('2026-04-01', '10000.00')],
    })

    const DEPOSIT_ON_DAY_TWO: CandlesResponse = payload({
      candles: [
        candle('2026-04-01', '0.00', '0.00'),
        candle('2026-04-02', '9000.00', '9000.00'),
      ],
      cash: [cash('2026-04-01', '0.00'), cash('2026-04-02', '1000.00')],
      flows: [flow('2026-04-02', '10000.00')],
    })

    it('DISCARDS a day-one deposit: the baseline already contains it', () => {
      const { baseCents, points } = deriveContributions(DEPOSIT_ON_DAY_ONE)
      // Baseline = holdings open 9,000 + END-OF-DAY cash 1,000 = 10,000. A start-of-day
      // series would give 9,000 here and a phantom +1,000 of growth below.
      expect(baseCents).toBe(1_000_000)
      expect(points[0]).toEqual({
        t: '2026-04-01',
        valueCents: 1_000_000,
        contributedCents: 1_000_000,
        growthCents: 0,
      })
      // The deposit is counted exactly once, not twice.
      expect(points[1].contributedCents).toBe(1_000_000)
      expect(points[1].growthCents).toBe(90_000)
    })

    it('ACCUMULATES the same deposit dated day two, and still reports growth 0', () => {
      const { baseCents, points } = deriveContributions(DEPOSIT_ON_DAY_TWO)
      expect(baseCents).toBe(0)
      expect(points[0]).toEqual({
        t: '2026-04-01',
        valueCents: 0,
        contributedCents: 0,
        growthCents: 0,
      })
      expect(points[1]).toEqual({
        t: '2026-04-02',
        valueCents: 1_000_000,
        contributedCents: 1_000_000,
        growthCents: 0,
      })
    })

    it('reports growth 0 on the deposit day in BOTH — depositing is not a gain', () => {
      // The property that ties the pair together. If either fixture stood alone, one
      // half of the convention would be untested.
      expect(deriveContributions(DEPOSIT_ON_DAY_ONE).points[0].growthCents).toBe(0)
      expect(deriveContributions(DEPOSIT_ON_DAY_TWO).points[1].growthCents).toBe(0)
    })
  })

  it('is byte-identical to the pre-cash derivation when cash is null', () => {
    // THE NO-REGRESSION PIN. Adding cash-aware arithmetic must not touch a single cent
    // for an untracked portfolio, which is every portfolio that exists today.
    expect(deriveContributions(payload())).toEqual({
      baseCents: 100_000,
      points: [
        { t: '2026-01-05', valueCents: 105_000, contributedCents: 100_000, growthCents: 5_000 },
        { t: '2026-01-06', valueCents: 103_000, contributedCents: 100_000, growthCents: 3_000 },
        { t: '2026-01-07', valueCents: 153_000, contributedCents: 150_000, growthCents: 3_000 },
        { t: '2026-01-08', valueCents: 135_000, contributedCents: 140_000, growthCents: -5_000 },
        { t: '2026-01-09', valueCents: 145_000, contributedCents: 140_000, growthCents: 5_000 },
      ],
    })
  })

  it('reads an all-zero cash series as identical to no cash at all', () => {
    const zeros = CANDLES.map((c) => cash(c.t, '0.00'))
    expect(deriveContributions(payload({ cash: zeros }))).toEqual(
      deriveContributions(payload()),
    )
  })

  it('treats a swept day missing from the cash series as zero, not as NaN', () => {
    // The series is end-of-day and the backend emits one point per swept day, so an
    // absent point means no movement had happened yet.
    const { points } = deriveContributions(
      payload({ cash: [cash('2026-01-08', '1000.00')] }),
    )
    expect(points[0].valueCents).toBe(105_000)
    expect(points[3].valueCents).toBe(135_000 + 100_000)
  })

  it('treats unparseable cash as zero rather than poisoning every later day', () => {
    const { points } = deriveContributions(
      payload({ cash: CANDLES.map((c) => cash(c.t, 'n/a')) }),
    )
    expect(points.map((p) => p.valueCents)).toEqual([
      105_000, 103_000, 153_000, 135_000, 145_000,
    ])
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
