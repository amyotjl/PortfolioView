import type { Summary } from '@/types'
import { toCents } from '@/lib/money'
import { formatCurrency, formatPercent, formatSignedPercent } from '@/lib/format'

/**
 * Turn a /summary payload into the dashboard stat-tile view models. Pure and
 * decimal-string-safe (formatting only — never client-side money math), so it
 * unit-tests the null handling directly (backlog #044 / #48).
 *
 * IMPORTANT: tiles come from /summary ONLY, never derived from a windowed
 * candles payload (docs/PLAN.md). Percentages arrive as 6dp FRACTIONS and are
 * rendered ×100 by the percent formatters. Any of total_return_pct,
 * benchmark_return_pct and vs_benchmark_edge_pct may be null (net_deposits ≤ 0
 * or no benchmark) → rendered as an em-dash.
 *
 * EIGHT TILES OR SIX (#80). A portfolio that records cash gets a `Holdings` and a
 * `Cash` tile; one that doesn't gets neither. The negative-cash story is only
 * legible with both side by side ("positions worth $12,400, cash −$3,240"), and
 * burying cash under the hero would leave the warning pointing at a figure that
 * isn't on screen.
 *
 * THE DISCRIMINATOR IS `cash_balance !== null`, and this is the single most
 * important line in the file. `null` means "does not track cash"; `'0.00'` means
 * "tracks cash and is exactly flat". Both are reachable and they mean different
 * things, so there is no `?? 0` / `|| 0` / `.default()` anywhere in this chain —
 * one of them would give every pre-existing trades-only portfolio a Cash tile
 * claiming a $0.00 balance it never recorded. `summaryTiles.spec.ts` pins the
 * other half: `cash_balance: '0.00'` STILL produces the Cash tile.
 *
 * `deposit_basis` is read only for COPY (which hint the Net deposits tile wears),
 * never for tile presence — one payload, one decision, no way for the two to
 * disagree.
 */
export type TileSign = 'up' | 'down' | 'neutral' | 'warn'

export interface SummaryTile {
  key: string
  label: string
  value: string
  /** Optional secondary line (e.g. the percent under a dollar return). */
  sub?: string
  /** Directional color hint; meaning is also carried by the signed text + label. */
  sign: TileSign
  /** Small caption under the tile. */
  hint?: string
  /** The single lead tile (rendered larger). */
  hero?: boolean
}

export const EM_DASH = '—'

/** Sign of a decimal string, treating null/blank as neutral (no float math). */
function signOf(value: string | null | undefined): TileSign {
  if (value === null || value === undefined || value === '') return 'neutral'
  const n = Number(value)
  if (!Number.isFinite(n) || n === 0) return 'neutral'
  return n > 0 ? 'up' : 'down'
}

/**
 * Cash polarity, which is NOT gain/loss polarity.
 *
 * `assets/main.css` reserves up/down strictly for data polarity — "a colored
 * number always means a real gain or loss" — and a negative cash balance is not a
 * loss, it is a bookkeeping gap. So negative cash is `'warn'`, and positive cash is
 * `'neutral'` and never `'up'`: holding cash is not a gain either.
 *
 * Decided on CENT-ROUNDED integer cents, so a -$0.000004 residual reads as flat
 * rather than lighting up a warning.
 */
function cashSign(cashBalance: string | null): TileSign {
  const cents = toCents(cashBalance ?? '')
  return cents !== null && cents < 0 ? 'warn' : 'neutral'
}

function money(value: string | null | undefined): string {
  return value === null || value === undefined ? EM_DASH : formatCurrency(value)
}

function signedPct(fraction: string | null | undefined): string {
  return fraction === null || fraction === undefined ? EM_DASH : formatSignedPercent(fraction)
}

function pct(fraction: string | null | undefined): string {
  return fraction === null || fraction === undefined ? EM_DASH : formatPercent(fraction)
}

/**
 * Where the reporting basis is communicated: ONCE, on the tile that *is* the
 * denominator, through the always-visible hint slot.
 *
 * Not a tooltip — there is no tooltip component in the app, PrimeVue's unstyled one
 * would need a new PT preset plus accessible-name plumbing (the family of bugs that
 * already cost #65/#69/#70), and a hover-only affordance violates the same rule the
 * chart table twins exist to satisfy.
 *
 * The trade-basis wording also fixes a live inaccuracy: today's hint reads
 * "Contributions minus withdrawals", which describes only the cash basis.
 */
function netDepositsHint(summary: Summary | null): string {
  return summary?.deposit_basis === 'cash'
    ? 'Deposits minus withdrawals'
    : 'From trade cost — no deposits recorded'
}

/**
 * Explains the em-dash on `total_return`'s percent line, which is null whenever
 * `net_deposits ≤ 0` — far more reachable under the cash basis (withdraw more than
 * you deposited and the deposit base goes to zero or below). Today that em-dash is
 * unexplained.
 */
function totalReturnHint(summary: Summary | null): string | undefined {
  if (!summary || summary.total_return_pct !== null) return undefined
  return 'A return percentage needs a positive deposit base.'
}

/**
 * The one longer line, on the "Lifetime performance" section header rather than in a
 * tile: an invitation to adopt cash tracking, shown only when the basis is trades
 * AND the portfolio actually has history to reinterpret.
 *
 * `as_of !== null` is that second condition, derived from this one payload rather
 * than by adding a query: a priced day exists only if there is at least one
 * transaction or one cash row, and a cash row would have flipped the basis to
 * 'cash' — so on the trade basis `as_of !== null` is exactly "has ≥ 1 transaction".
 *
 * Deliberately NOT a dismissable banner: that needs client state and a persistence
 * decision, for a line of small print.
 */
export function depositBasisAdvisory(summary: Summary | null | undefined): string | null {
  if (!summary || summary.deposit_basis !== 'trades' || summary.as_of === null) return null
  return (
    'Returns are measured against what you paid for your holdings. Record deposits ' +
    'and withdrawals on the Transactions page to measure them against the money you ' +
    'actually put in.'
  )
}

/** True when this payload's portfolio records cash. See the module note. */
export function tracksCash(summary: Summary | null | undefined): boolean {
  return summary?.cash_balance !== null && summary?.cash_balance !== undefined
}

export function buildSummaryTiles(summary: Summary | null | undefined): SummaryTile[] {
  const s = summary ?? null

  const tiles: SummaryTile[] = [
    {
      key: 'current_value',
      // Renamed from "Current value": a renamed label is the OPPOSITE of a silent
      // redefinition, and "Total value" is true in both bases (it is holdings +
      // cash when cash is tracked, and holdings when it isn't).
      label: 'Total value',
      value: money(s?.current_value),
      sign: 'neutral',
      hero: true,
    },
  ]

  if (tracksCash(s)) {
    tiles.push(
      {
        key: 'holdings_value',
        label: 'Holdings',
        value: money(s?.holdings_value),
        sign: 'neutral',
      },
      {
        key: 'cash_balance',
        label: 'Cash',
        value: money(s?.cash_balance),
        sign: cashSign(s?.cash_balance ?? null),
      },
    )
  }

  tiles.push(
    {
      key: 'net_deposits',
      label: 'Net deposits',
      value: money(s?.net_deposits),
      sign: 'neutral',
      hint: netDepositsHint(s),
    },
    {
      key: 'total_return',
      label: 'Total return',
      value: money(s?.total_return),
      sub: signedPct(s?.total_return_pct ?? null),
      sign: signOf(s?.total_return),
      hint: totalReturnHint(s),
    },
    {
      key: 'benchmark_return_pct',
      label: 'Benchmark return',
      value: signedPct(s?.benchmark_return_pct ?? null),
      sign: signOf(s?.benchmark_return_pct ?? null),
    },
    {
      key: 'vs_benchmark_edge_pct',
      label: 'Vs. benchmark',
      value: signedPct(s?.vs_benchmark_edge_pct ?? null),
      sign: signOf(s?.vs_benchmark_edge_pct ?? null),
      hint: 'Your return minus the benchmark',
    },
    {
      key: 'max_drawdown_pct',
      label: 'Max drawdown',
      value: pct(s?.max_drawdown_pct),
      // Drawdown is a loss magnitude (≤ 0): red when non-zero, else neutral.
      sign: signOf(s?.max_drawdown_pct) === 'down' ? 'down' : 'neutral',
    },
  )

  return tiles
}

/**
 * How many skeletons the loading row renders.
 *
 * The basis is UNKNOWN while /summary is in flight, so the skeleton shows the
 * untracked count and a portfolio that turns out to track cash reflows once. That
 * is the accepted cost: persisting "this portfolio tracks cash" client-side would
 * be inventing client state for server data, which PLAN.md forbids.
 *
 * Derived from the builder rather than hardcoded (`StatTileRow.vue` used to carry a
 * literal `v-for="n in 6"`), so the count cannot drift from the tile set again.
 */
export const SKELETON_TILE_COUNT = buildSummaryTiles(null).length
