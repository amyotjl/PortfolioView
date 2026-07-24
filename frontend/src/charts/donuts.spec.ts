import { describe, expect, it } from 'vitest'
import {
  buildAllocationDonutOption,
  instrumentDonutRows,
  sectorDonutRows,
  type DonutRow,
} from './donuts'
import { LIGHT_CHART_THEME as theme } from './theme'
import type { Allocations } from '@/types'

const alloc: Allocations = {
  as_of: '2026-01-06',
  total_value: '10000.00',
  by_instrument: [
    { instrument_id: 1, symbol: 'AAPL', value: '6000.00', weight: '0.6' },
    { instrument_id: 2, symbol: null, value: '4000.00', weight: '0.4' },
  ],
  by_sector: [
    { sector: 'Technology', value: '6000.00', weight: '0.6' },
    { sector: 'ETF / Fund', value: '4000.00', weight: '0.4' },
  ],
}

interface DonutOptShape {
  series: Array<{
    type?: string
    data?: Array<{ name?: string; value?: number; valueStr?: string; itemStyle?: { color?: string } }>
  }>
  tooltip: { formatter: (p: unknown) => string }
}

function build(rows: DonutRow[]) {
  return buildAllocationDonutOption(rows, theme, { name: 'x' }) as unknown as DonutOptShape
}

describe('donut row mappers', () => {
  it('falls back to #<id> when an instrument has no symbol', () => {
    const rows = instrumentDonutRows(alloc)
    expect(rows.map((r) => r.name)).toEqual(['AAPL', '#2'])
    expect(rows[0]).toMatchObject({ value: 6000, valueStr: '6000.00', weightStr: '0.6' })
  })

  it('passes the server-provided "ETF / Fund" sector bucket through', () => {
    const rows = sectorDonutRows(alloc)
    expect(rows.map((r) => r.name)).toEqual(['Technology', 'ETF / Fund'])
  })
})

describe('buildAllocationDonutOption', () => {
  it('builds a pie with a slice per row, each colored from the ordinal ramp', () => {
    const opt = build(instrumentDonutRows(alloc))
    const data = opt.series[0].data ?? []
    expect(opt.series[0].type).toBe('pie')
    expect(data).toHaveLength(2)
    expect(data[0].name).toBe('AAPL')
    expect(data[0].itemStyle?.color).toBeTruthy()
    expect(data[1].itemStyle?.color).toBeTruthy()
    // Ordinal ramp: adjacent slices are distinct steps, never a cycled hue.
    expect(data[0].itemStyle?.color).not.toBe(data[1].itemStyle?.color)
  })

  it('renders the "ETF / Fund" bucket as a sector slice', () => {
    const opt = build(sectorDonutRows(alloc))
    const names = (opt.series[0].data ?? []).map((d) => d.name)
    expect(names).toContain('ETF / Fund')
  })

  it('tooltip shows the slice value and weight at full precision', () => {
    const opt = build(instrumentDonutRows(alloc))
    const html = opt.tooltip.formatter({
      name: 'AAPL',
      color: '#123456',
      data: { valueStr: '6000.00', weightStr: '0.6' },
    })
    expect(html).toContain('AAPL')
    expect(html).toContain('$6,000.00')
    expect(html).toContain('60.00%')
  })

  it('escapes untrusted slice names in the tooltip', () => {
    const opt = build([{ name: '<b>x</b>', value: 1, valueStr: '1', weightStr: '1' }])
    const html = opt.tooltip.formatter({
      name: '<b>x</b>',
      color: '#123456',
      data: { valueStr: '1', weightStr: '1' },
    })
    expect(html).toContain('&lt;b&gt;x&lt;/b&gt;')
    expect(html).not.toContain('<b>x</b>')
  })

  it('handles an empty allocation without throwing', () => {
    const opt = build([])
    expect(opt.series[0].data).toEqual([])
  })
})
