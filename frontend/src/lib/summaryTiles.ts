import type { Summary } from '@/types'
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
 */
export type TileSign = 'up' | 'down' | 'neutral'

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

function money(value: string | null | undefined): string {
  return value === null || value === undefined ? EM_DASH : formatCurrency(value)
}

function signedPct(fraction: string | null | undefined): string {
  return fraction === null || fraction === undefined ? EM_DASH : formatSignedPercent(fraction)
}

function pct(fraction: string | null | undefined): string {
  return fraction === null || fraction === undefined ? EM_DASH : formatPercent(fraction)
}

export function buildSummaryTiles(summary: Summary | null | undefined): SummaryTile[] {
  const s = summary ?? null
  return [
    {
      key: 'current_value',
      label: 'Current value',
      value: money(s?.current_value),
      sign: 'neutral',
      hero: true,
    },
    {
      key: 'total_return',
      label: 'Total return',
      value: money(s?.total_return),
      sub: signedPct(s?.total_return_pct ?? null),
      sign: signOf(s?.total_return),
    },
    {
      key: 'net_deposits',
      label: 'Net deposits',
      value: money(s?.net_deposits),
      sign: 'neutral',
      hint: 'Contributions minus withdrawals',
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
  ]
}
