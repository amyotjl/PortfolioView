import { describe, expect, it } from 'vitest'
import { buildSummaryTiles, EM_DASH, type SummaryTile } from './summaryTiles'
import type { Summary } from '@/types'

const full: Summary = {
  current_value: '12345.67',
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
  current_value: '0.00',
  net_deposits: '0.00',
  total_return: '0.00',
  total_return_pct: null,
  benchmark_return_pct: null,
  vs_benchmark_edge_pct: null,
  max_drawdown_pct: '0',
  as_of: null,
}

function byKey(tiles: SummaryTile[], key: string): SummaryTile {
  const tile = tiles.find((t) => t.key === key)
  if (!tile) throw new Error(`missing tile ${key}`)
  return tile
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
})
