import { describe, expect, it } from 'vitest'
import {
  buildSectorTreemapOption,
  renderTreemapTooltip,
  sectorTreemapNodes,
  treemapLeafLabel,
  treemapSectorLabel,
  type TreemapSectorNode,
} from './treemap'
import { buildAllocationDonutOption, sectorDonutRows } from './donuts'
import { DARK_CHART_THEME, LIGHT_CHART_THEME as theme } from './theme'
import { contrastRatio, sampleRamp } from './colors'
import type { Allocations } from '@/types'

/**
 * Three sectors, largest-first as the server orders them, with the sector-less
 * "ETF / Fund" bucket present and a multi-holding sector so the child fade has
 * something to run across.
 *
 *   Technology  6000 (0.6)  <- AAPL 4000 (0.4), MSFT 2000 (0.2)
 *   ETF / Fund  3000 (0.3)  <- VTI  3000 (0.3)
 *   Healthcare  1000 (0.1)  <- #7   1000 (0.1)  (null symbol)
 */
const alloc: Allocations = {
  as_of: '2026-07-24',
  total_value: '10000.00',
  by_instrument: [
    { instrument_id: 1, symbol: 'AAPL', sector: 'Technology', value: '4000.00', weight: '0.4' },
    { instrument_id: 3, symbol: 'VTI', sector: 'ETF / Fund', value: '3000.00', weight: '0.3' },
    { instrument_id: 2, symbol: 'MSFT', sector: 'Technology', value: '2000.00', weight: '0.2' },
    { instrument_id: 7, symbol: null, sector: 'Healthcare', value: '1000.00', weight: '0.1' },
  ],
  by_sector: [
    { sector: 'Technology', value: '6000.00', weight: '0.6' },
    { sector: 'ETF / Fund', value: '3000.00', weight: '0.3' },
    { sector: 'Healthcare', value: '1000.00', weight: '0.1' },
  ],
}

function nodes(a: Allocations = alloc): TreemapSectorNode[] {
  return sectorTreemapNodes(a, theme)
}

describe('sectorTreemapNodes', () => {
  it('builds the sector -> instrument hierarchy, keeping the server order', () => {
    const built = nodes()
    expect(built.map((n) => n.name)).toEqual(['Technology', 'ETF / Fund', 'Healthcare'])
    expect(built.map((n) => n.children.map((c) => c.name))).toEqual([
      ['AAPL', 'MSFT'],
      ['VTI'],
      ['#7'],
    ])
  })

  it('includes the "ETF / Fund" bucket as a sector of its own', () => {
    const etf = nodes().find((n) => n.name === 'ETF / Fund')
    expect(etf).toBeDefined()
    expect(etf?.valueStr).toBe('3000.00')
    expect(etf?.children.map((c) => c.name)).toEqual(['VTI'])
  })

  it('sizes nodes by market value and carries the raw strings for the tooltip', () => {
    const [tech] = nodes()
    expect(tech.value).toBe(6000)
    expect(tech).toMatchObject({ valueStr: '6000.00', weightStr: '0.6' })
    expect(tech.children[0]).toMatchObject({
      value: 4000,
      valueStr: '4000.00',
      weightStr: '0.4',
      sector: 'Technology',
    })
  })

  it("a child's value never exceeds its parent, and children sum to it", () => {
    for (const node of nodes()) {
      const childSum = node.children.reduce((sum, c) => sum + c.value, 0)
      expect(childSum).toBeCloseTo(node.value, 10)
    }
  })

  it('falls back to #<id> for a null symbol, exactly like the donuts', () => {
    const healthcare = nodes().find((n) => n.name === 'Healthcare')
    expect(healthcare?.children[0].name).toBe('#7')
  })

  it('gives sectors the SAME colors the by_sector donut computes', () => {
    // Cross-chart consistency is the point of reusing donutRamp: a sector must
    // not change color between the donut and the treemap on one dashboard.
    const donut = buildAllocationDonutOption(sectorDonutRows(alloc), theme, {
      name: 'By sector',
    }) as unknown as { series: Array<{ data: Array<{ name: string; itemStyle: { color: string } }> }> }
    const donutColors = new Map(donut.series[0].data.map((d) => [d.name, d.itemStyle.color]))

    for (const node of nodes()) {
      expect(node.sectorColor, node.name).toBe(donutColors.get(node.name))
    }
  })

  it('keeps the sector CONTAINER on the surface with a plain ink header', () => {
    // REGRESSION (found by looking at the rendered chart): ECharts draws a sector's
    // header strip on the chart background, not filled with the node's color. An
    // ink picked to contrast with the sector color was therefore white-on-white for
    // dark sectors, and the "ETF / Fund" header simply did not appear.
    for (const node of nodes()) {
      expect(node.itemStyle.color, node.name).toBe(theme.panel)
      expect(node.upperLabel.color, node.name).toBe(theme.ink)
      expect(contrastRatio(theme.panel, node.upperLabel.color)).toBeGreaterThanOrEqual(4.5)
    }
  })

  it('fades children away from the parent color, largest child wearing it exactly', () => {
    const [tech] = nodes()
    const sectorColor = sampleRamp(theme.donutRamp, 3)[0]
    expect(tech.children[0].itemStyle.color).toBe(sectorColor)
    expect(tech.children[1].itemStyle.color).not.toBe(sectorColor)
    // A lone child gets the parent color, not a fade of it.
    const etf = nodes().find((n) => n.name === 'ETF / Fund')
    expect(etf?.children[0].itemStyle.color).toBe(sampleRamp(theme.donutRamp, 3)[1])
  })

  it('picks a label ink that actually contrasts with each tile', () => {
    // Leaf labels DO sit inside a colored fill spanning the whole ramp, so a single
    // fixed ink is unreadable at one end of it; every tile's label must beat the
    // 3:1 large-text floor against its own fill.
    for (const node of nodes()) {
      for (const child of node.children) {
        expect(
          contrastRatio(child.itemStyle.color, child.label.color),
          `${node.name}/${child.name}`,
        ).toBeGreaterThanOrEqual(3)
      }
    }
  })

  it('derives child shades from the sector color, both themes', () => {
    // The ramp differs per theme, so a leaf ink chosen against the light ramp must
    // not be assumed to work on the dark one.
    for (const t of [theme, DARK_CHART_THEME]) {
      for (const node of sectorTreemapNodes(alloc, t)) {
        for (const child of node.children) {
          expect(
            contrastRatio(child.itemStyle.color, child.label.color),
            `${node.name}/${child.name}`,
          ).toBeGreaterThanOrEqual(3)
        }
      }
    }
  })

  it('emits a sector present only in by_instrument rather than dropping holdings', () => {
    const orphaned: Allocations = {
      ...alloc,
      by_instrument: [
        ...alloc.by_instrument,
        { instrument_id: 9, symbol: 'XYZ', sector: 'Energy', value: '500.00', weight: '0.05' },
      ],
    }
    const built = sectorTreemapNodes(orphaned, theme)
    expect(built.map((n) => n.name)).toEqual([
      'Technology',
      'ETF / Fund',
      'Healthcare',
      'Energy', // appended after the known sectors
    ])
    expect(built[3]).toMatchObject({ value: 500, valueStr: '500.00' })
  })

  it('drops a by_sector entry that has no holdings instead of drawing an empty box', () => {
    const stale: Allocations = {
      ...alloc,
      by_sector: [...alloc.by_sector, { sector: 'Utilities', value: '0.00', weight: '0.0' }],
    }
    expect(sectorTreemapNodes(stale, theme).map((n) => n.name)).not.toContain('Utilities')
  })

  it('returns no nodes for an empty portfolio, so the caller can show an empty state', () => {
    expect(
      sectorTreemapNodes(
        { as_of: null, total_value: '0.0', by_instrument: [], by_sector: [] },
        theme,
      ),
    ).toEqual([])
  })
})

describe('labels', () => {
  it('puts the ticker over its weight on an instrument tile', () => {
    expect(treemapLeafLabel({ name: 'AAPL', data: { weightStr: '0.4' } })).toBe('AAPL\n40.00%')
  })

  it('puts the sector beside its weight in the container header', () => {
    expect(treemapSectorLabel({ name: 'Technology', data: { weightStr: '0.6' } })).toBe(
      'Technology · 60.00%',
    )
  })

  it('omits the weight rather than printing an empty percentage', () => {
    expect(treemapLeafLabel({ name: 'AAPL' })).toBe('AAPL')
    expect(treemapSectorLabel({ name: 'Technology' })).toBe('Technology')
  })
})

describe('renderTreemapTooltip', () => {
  it('shows value and weight for a tile', () => {
    const html = renderTreemapTooltip(
      { name: 'AAPL', data: { valueStr: '4000.00', weightStr: '0.4', sector: 'Technology' } },
      theme,
    )
    expect(html).toContain('AAPL')
    expect(html).toContain('$4,000.00')
    expect(html).toContain('40.00%')
    expect(html).toContain('Technology') // parent sector locates a small tile
  })

  it('does not repeat the sector as its own parent on a container', () => {
    const html = renderTreemapTooltip(
      { name: 'Technology', data: { valueStr: '6000.00', weightStr: '0.6', sector: 'Technology' } },
      theme,
    )
    expect(html.match(/Technology/g)).toHaveLength(1)
  })

  it('escapes names — sector and ticker strings are untrusted API data', () => {
    const html = renderTreemapTooltip(
      { name: '<img src=x onerror=alert(1)>', data: { valueStr: '1.00', weightStr: '1.0' } },
      theme,
    )
    expect(html).not.toContain('<img')
    expect(html).toContain('&lt;img')
  })

  it('renders em-dashes instead of NaN when a figure is missing', () => {
    const html = renderTreemapTooltip({ name: 'AAPL' }, theme)
    expect(html).toContain('—')
    expect(html).not.toContain('NaN')
  })
})

interface TreemapOptionShape {
  series: Array<{
    type: string
    roam: boolean
    nodeClick: boolean
    itemStyle: { gapWidth: number; borderColor: string }
    label: { overflow: string }
    levels: Array<{ upperLabel?: { show?: boolean } }>
    data: TreemapSectorNode[]
  }>
  tooltip: { formatter: (p: unknown) => string }
}

function build(a: Allocations = alloc): TreemapOptionShape {
  return buildSectorTreemapOption(nodes(a), theme) as unknown as TreemapOptionShape
}

describe('buildSectorTreemapOption', () => {
  it('is a treemap carrying the hierarchy as its data', () => {
    const [series] = build().series
    expect(series.type).toBe('treemap')
    expect(series.data.map((n) => n.name)).toEqual(['Technology', 'ETF / Fund', 'Healthcare'])
  })

  it('separates tiles with a 2px SURFACE gap, not a border around each mark', () => {
    const [series] = build().series
    expect(series.itemStyle.gapWidth).toBe(2)
    expect(series.itemStyle.borderColor).toBe(theme.panel)
  })

  it('truncates a label rather than letting it overflow its tile', () => {
    expect(build().series[0].label.overflow).toBe('truncate')
  })

  it('hides the ROOT header so the series name is not drawn as a band', () => {
    // REGRESSION: levels[] is indexed by depth and depth 0 is the invisible root,
    // so an inherited upperLabel there rendered "Allocation by sector" as a header
    // above the whole treemap — duplicating the card title.
    const { levels } = build().series[0]
    expect(levels[0].upperLabel?.show).toBe(false)
    expect(levels[1].upperLabel?.show).toBe(true)
  })

  it('leaves drill-down and roam off — the card shows one snapshot', () => {
    const [series] = build().series
    expect(series.roam).toBe(false)
    expect(series.nodeClick).toBe(false)
  })

  it('builds a valid empty option for an empty portfolio', () => {
    const option = buildSectorTreemapOption([], theme) as unknown as TreemapOptionShape
    expect(option.series[0].data).toEqual([])
  })
})
