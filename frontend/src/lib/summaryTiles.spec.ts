import { describe, expect, it } from 'vitest'
import {
  buildSummaryTiles,
  depositBasisAdvisory,
  tracksCash,
  EM_DASH,
  SKELETON_TILE_COUNT,
  type SummaryTile,
} from './summaryTiles'
import type { Summary } from '@/types'

/** A trades-only portfolio: `cash_balance` is null and `deposit_basis` is 'trades'. */
const full: Summary = {
  current_value: '12345.67',
  holdings_value: '12345.67',
  cash_balance: null,
  deposit_basis: 'trades',
  cash_negative: false,
  cash_negative_since: null,
  net_deposits: '10000.00',
  total_return: '2345.67',
  total_return_pct: '0.234567', // 6dp fraction -> +23.46%
  benchmark_return_pct: '0.15',
  vs_benchmark_edge_pct: '0.084567',
  max_drawdown_pct: '-0.0834',
  as_of: '2026-01-06',
}

// net_deposits <= 0 / no benchmark -> the percent fields are null.
const nullish: Summary = {
  ...full,
  current_value: '0.00',
  holdings_value: '0.00',
  net_deposits: '0.00',
  total_return: '0.00',
  total_return_pct: null,
  benchmark_return_pct: null,
  vs_benchmark_edge_pct: null,
  max_drawdown_pct: '0',
  as_of: null,
}

/** The same figures for a portfolio that DOES record cash. */
const tracked: Summary = {
  ...full,
  current_value: '15585.67',
  holdings_value: '12345.67',
  cash_balance: '3240.00',
  deposit_basis: 'cash',
}

function byKey(tiles: SummaryTile[], key: string): SummaryTile {
  const tile = tiles.find((t) => t.key === key)
  if (!tile) throw new Error(`missing tile ${key}`)
  return tile
}

function keys(summary: Summary | null): string[] {
  return buildSummaryTiles(summary).map((t) => t.key)
}

describe('buildSummaryTiles', () => {
  it('formats a fully populated summary (pcts as ×100 fractions)', () => {
    const tiles = buildSummaryTiles(full)
    expect(byKey(tiles, 'current_value')).toMatchObject({
      value: '$12,345.67',
      hero: true,
      sign: 'neutral',
    })
    expect(byKey(tiles, 'total_return')).toMatchObject({
      value: '$2,345.67',
      sub: '+23.46%',
      sign: 'up',
    })
    expect(byKey(tiles, 'net_deposits')).toMatchObject({ value: '$10,000.00', sign: 'neutral' })
    expect(byKey(tiles, 'benchmark_return_pct')).toMatchObject({ value: '+15.00%', sign: 'up' })
    expect(byKey(tiles, 'vs_benchmark_edge_pct')).toMatchObject({ value: '+8.46%', sign: 'up' })
    expect(byKey(tiles, 'max_drawdown_pct')).toMatchObject({ value: '-8.34%', sign: 'down' })
  })

  it('renders an em-dash for null percentages (no float coercion)', () => {
    const tiles = buildSummaryTiles(nullish)
    expect(byKey(tiles, 'total_return').sub).toBe(EM_DASH)
    expect(byKey(tiles, 'benchmark_return_pct').value).toBe(EM_DASH)
    expect(byKey(tiles, 'vs_benchmark_edge_pct').value).toBe(EM_DASH)
    // Non-null but zero: formatted, neutral sign.
    expect(byKey(tiles, 'max_drawdown_pct')).toMatchObject({ value: '0.00%', sign: 'neutral' })
  })

  it('renders em-dashes throughout when there is no summary yet', () => {
    const tiles = buildSummaryTiles(null)
    expect(tiles).toHaveLength(6)
    expect(byKey(tiles, 'current_value').value).toBe(EM_DASH)
    expect(byKey(tiles, 'total_return').value).toBe(EM_DASH)
  })

  it('labels the hero "Total value", which is true in BOTH bases', () => {
    // Renamed deliberately: the figure now includes cash for a tracked portfolio, and
    // a renamed label is the opposite of a silent redefinition.
    expect(byKey(buildSummaryTiles(full), 'current_value').label).toBe('Total value')
    expect(byKey(buildSummaryTiles(tracked), 'current_value').label).toBe('Total value')
  })
})

describe('the tile SET follows cash tracking, and only cash_balance decides it', () => {
  it('gives an untracked portfolio six tiles with no Holdings and no Cash', () => {
    expect(keys(full)).toEqual([
      'current_value',
      'net_deposits',
      'total_return',
      'benchmark_return_pct',
      'vs_benchmark_edge_pct',
      'max_drawdown_pct',
    ])
    expect(tracksCash(full)).toBe(false)
  })

  it('gives a tracked portfolio eight tiles, with Holdings and Cash beside the hero', () => {
    expect(keys(tracked)).toEqual([
      'current_value',
      'holdings_value',
      'cash_balance',
      'net_deposits',
      'total_return',
      'benchmark_return_pct',
      'vs_benchmark_edge_pct',
      'max_drawdown_pct',
    ])
    expect(tracksCash(tracked)).toBe(true)
    expect(byKey(buildSummaryTiles(tracked), 'holdings_value')).toMatchObject({
      label: 'Holdings',
      value: '$12,345.67',
      sign: 'neutral',
    })
    expect(byKey(buildSummaryTiles(tracked), 'cash_balance')).toMatchObject({
      label: 'Cash',
      value: '$3,240.00',
    })
  })

  /**
   * THE SINGLE HIGHEST-VALUE ASSERTION IN THIS FILE.
   *
   * `cash_balance: null` means "does not track cash"; `'0.00'` means "tracks cash and
   * is exactly flat". A `?? 0` / `|| 0` / `.default(0)` ANYWHERE in the chain — the zod
   * schema, this builder, or the component — collapses those two states into one, and
   * the visible symptom is exactly this: a portfolio that is genuinely flat loses its
   * Cash tile (or, in the other direction, every trades-only portfolio grows one).
   */
  it('STILL produces the Cash tile at cash_balance: "0.00"', () => {
    const flat: Summary = { ...tracked, cash_balance: '0.00', current_value: '12345.67' }
    expect(tracksCash(flat)).toBe(true)
    expect(keys(flat)).toHaveLength(8)
    expect(byKey(buildSummaryTiles(flat), 'cash_balance')).toMatchObject({
      label: 'Cash',
      value: '$0.00',
      // Flat is not a warning, and holding cash is never a gain.
      sign: 'neutral',
    })
  })

  it('drops both tiles the moment cash_balance is null, even on the cash basis', () => {
    // A defence-in-depth check on the discriminator: presence follows `cash_balance`,
    // never `deposit_basis`. The two cannot disagree in a real payload (contract test),
    // but if they ever did, the tile that has no figure must not render.
    expect(keys({ ...tracked, cash_balance: null })).toHaveLength(6)
  })
})

describe('cash polarity is NOT gain/loss polarity', () => {
  it('marks a negative balance "warn", never "down"', () => {
    // up/down are reserved app-wide for real gain/loss (assets/main.css). A negative
    // cash balance is a bookkeeping gap, not a loss.
    const negative: Summary = { ...tracked, cash_balance: '-3240.00', current_value: '9105.67' }
    expect(byKey(buildSummaryTiles(negative), 'cash_balance')).toMatchObject({
      value: '-$3,240.00',
      sign: 'warn',
    })
    expect(byKey(buildSummaryTiles(negative), 'cash_balance').sign).not.toBe('down')
  })

  it('never marks a positive balance "up" — holding cash is not a gain either', () => {
    expect(byKey(buildSummaryTiles(tracked), 'cash_balance').sign).toBe('neutral')
  })

  it('is decided on cent-rounded cents, so a sub-cent residual reads as flat', () => {
    const residual: Summary = { ...tracked, cash_balance: '-0.000004' }
    expect(byKey(buildSummaryTiles(residual), 'cash_balance').sign).toBe('neutral')
  })
})

describe('the basis is communicated on the tile that IS the denominator', () => {
  it('describes the cash basis as deposits minus withdrawals', () => {
    expect(byKey(buildSummaryTiles(tracked), 'net_deposits').hint).toBe(
      'Deposits minus withdrawals',
    )
  })

  it('names the trade basis honestly instead of describing the cash one', () => {
    // The old hint read "Contributions minus withdrawals", which described only the
    // cash basis and so was a live inaccuracy on every existing portfolio.
    expect(byKey(buildSummaryTiles(full), 'net_deposits').hint).toBe(
      'From trade cost — no deposits recorded',
    )
  })

  it('explains the em-dash whenever the return percentage is null', () => {
    expect(byKey(buildSummaryTiles(nullish), 'total_return').hint).toBe(
      'A return percentage needs a positive deposit base.',
    )
  })

  it('does not add that hint when there IS a percentage, or when there is no summary', () => {
    expect(byKey(buildSummaryTiles(full), 'total_return').hint).toBeUndefined()
    expect(byKey(buildSummaryTiles(null), 'total_return').hint).toBeUndefined()
  })
})

describe('depositBasisAdvisory', () => {
  it('invites a trade-basis portfolio WITH history to record deposits', () => {
    expect(depositBasisAdvisory(full)).toBe(
      'Returns are measured against what you paid for your holdings. Record deposits ' +
        'and withdrawals on the Transactions page to measure them against the money you ' +
        'actually put in.',
    )
  })

  it('stays silent on the cash basis — there is nothing to invite', () => {
    expect(depositBasisAdvisory(tracked)).toBeNull()
  })

  it('stays silent for a portfolio with no priced day yet', () => {
    // `as_of !== null` is how "has >= 1 transaction" is derived from this one payload:
    // a priced day needs a transaction or a cash row, and a cash row would have flipped
    // the basis to 'cash'. So an empty portfolio is never nagged.
    expect(depositBasisAdvisory({ ...full, as_of: null })).toBeNull()
  })

  it('stays silent while /summary is still loading', () => {
    expect(depositBasisAdvisory(null)).toBeNull()
    expect(depositBasisAdvisory(undefined)).toBeNull()
  })
})

describe('SKELETON_TILE_COUNT', () => {
  it('tracks the untracked tile count rather than a hardcoded 6', () => {
    // The basis is unknown while /summary is in flight, so the loading row shows the
    // untracked count and a cash portfolio reflows once. Deriving it from the builder
    // is what stops the two drifting apart, as the literal `v-for="n in 6"` could.
    expect(SKELETON_TILE_COUNT).toBe(buildSummaryTiles(null).length)
    expect(SKELETON_TILE_COUNT).toBe(6)
  })
})
