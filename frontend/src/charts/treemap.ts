/**
 * Pure builder for the sector treemap (backlog #049 / #53), fed by GET
 * /allocations: `by_sector` supplies the sector containers (authoritative value
 * and weight, already largest-first) and `by_instrument` supplies the tiles inside
 * them, joined on the `sector` label the two breakdowns share.
 *
 * That join key exists because it has to: the two breakdowns are otherwise flat
 * lists with nothing in common, and an instrument's sector is not reachable from
 * the frontend by any other route (`/instruments/search` is the separate
 * `listed_instruments` directory with independent ids — see lib/instrumentIds.ts).
 * It was added to the serializer for this chart; docs/API_SHAPES.md documents it.
 *
 * COLOR — the same ordinal ramp as the by_sector donut, deliberately
 * ---------------------------------------------------------------
 * Sectors take `sampleRamp(theme.donutRamp, sectorCount)` in the server's
 * largest-first order, which is *exactly* what buildAllocationDonutOption computes
 * for the same payload. So a sector is the same color in both allocation views —
 * a reader who learned "Technology is the dark blue" in the donut keeps that
 * reading here.
 *
 * A lightness ramp over nominal categories is normally a dataviz anti-pattern
 * (it double-encodes magnitude as hue). It is right here for the same reason the
 * donut documents: a treemap's layout is *itself* magnitude-ordered, so the ramp
 * reinforces the order the geometry already states rather than inventing a second
 * meaning — and unlike the 8-hue categorical ceiling it does not break down at
 * 10+ sectors, which a diversified portfolio genuinely reaches. Identity never
 * rests on hue: every tile is directly labeled, the tooltip carries value and
 * weight, and the table twin lists both for every row.
 *
 * Instruments within a sector are lighter steps of their parent's color (largest
 * child = the parent color itself), so tile-to-sector membership is readable
 * without relying on the container border alone.
 *
 * Pure and DOM-free: ECharts *types* only, no runtime import — the same property
 * that makes candles.ts and donuts.ts unit-testable without a browser.
 */
import type { EChartsOption, TreemapSeriesOption } from 'echarts'
import type { Allocations } from '@/types'
import type { ChartTheme } from './theme'
import { escapeHtml, mixHex, readableInk, sampleRamp } from './colors'
import { formatCurrency, formatPercent } from '@/lib/format'

/** How far the smallest child is mixed toward the surface, away from its parent. */
const CHILD_FADE = 0.45

/** An instrument tile. `value` drives the area; the raw strings feed the tooltip. */
export interface TreemapLeaf {
  name: string
  value: number
  valueStr: string
  weightStr: string
  sector: string
  itemStyle: { color: string }
  label: { color: string }
}

/** A sector container plus its instrument tiles. */
export interface TreemapSectorNode {
  name: string
  value: number
  valueStr: string
  weightStr: string
  /**
   * The sector's identity color — the same ramp step the by_sector donut uses, and
   * the shade its children are derived from. Deliberately NOT the container's own
   * fill: see `itemStyle` below.
   */
  sectorColor: string
  /**
   * The container's fill is the SURFACE, not the sector color. A sector container
   * is visible only as its header strip, and ECharts draws that strip on the chart
   * background rather than filling it with the node's color — so a colored fill
   * here would never be seen, while a header ink chosen to contrast with it was
   * invisible against the surface it actually lands on (an "ETF / Fund" header in
   * white-on-white; only light-colored sectors happened to render at all).
   * Keeping the container on-surface also avoids a large saturated block.
   */
  itemStyle: { color: string }
  /** Header text wears a plain text token, since it sits on the card surface. */
  upperLabel: { color: string }
  children: TreemapLeaf[]
}

/** A row's display name; a null symbol falls back to a stable `#<id>` (as in the donuts). */
function leafName(row: Allocations['by_instrument'][number]): string {
  return row.symbol ?? `#${row.instrument_id}`
}

/**
 * Build the sector -> instrument hierarchy. Pure. Empty allocations yield an empty
 * array, so the caller can render an empty state instead of an empty chart.
 *
 * Sector order follows `by_sector` (server-ordered largest-first) so the ramp
 * matches the donut. A sector that somehow appears only in `by_instrument` is
 * still emitted — appended after the known ones, largest-first — rather than
 * silently dropping holdings; the API contract test pins the join, so this is a
 * belt-and-braces path, not an expected one.
 */
export function sectorTreemapNodes(
  alloc: Allocations,
  theme: ChartTheme,
): TreemapSectorNode[] {
  const bySector = new Map<string, Allocations['by_instrument']>()
  for (const row of alloc.by_instrument) {
    const existing = bySector.get(row.sector)
    if (existing) existing.push(row)
    else bySector.set(row.sector, [row])
  }

  const known = alloc.by_sector.filter((s) => bySector.has(s.sector))
  const extra = [...bySector.keys()]
    .filter((sector) => !alloc.by_sector.some((s) => s.sector === sector))
    .map((sector) => {
      const rows = bySector.get(sector) as Allocations['by_instrument']
      const total = rows.reduce((sum, r) => sum + Number(r.value), 0)
      const weight = rows.reduce((sum, r) => sum + Number(r.weight), 0)
      return { sector, value: total.toFixed(2), weight: String(weight) }
    })
    .sort((a, b) => Number(b.value) - Number(a.value))

  const sectors = [...known, ...extra]
  const colors = sampleRamp(theme.donutRamp, sectors.length)

  return sectors.map((sectorSlice, i) => {
    const sectorColor = colors[i]
    // Rows arrive largest-first from the server; keep that order so the largest
    // child wears the parent color exactly and the fade runs with the layout.
    const rows = bySector.get(sectorSlice.sector) as Allocations['by_instrument']

    const children: TreemapLeaf[] = rows.map((row, childIndex) => {
      const fade = rows.length > 1 ? (childIndex / (rows.length - 1)) * CHILD_FADE : 0
      const color = mixHex(sectorColor, theme.panel, fade)
      return {
        name: leafName(row),
        value: Number(row.value),
        valueStr: row.value,
        weightStr: row.weight,
        sector: sectorSlice.sector,
        itemStyle: { color },
        // A tile's fill spans the ramp, so its label picks the readable ink.
        label: { color: readableInk(color, theme.panel, theme.ink) },
      }
    })

    return {
      name: sectorSlice.sector,
      value: Number(sectorSlice.value),
      valueStr: sectorSlice.value,
      weightStr: sectorSlice.weight,
      sectorColor,
      itemStyle: { color: theme.panel },
      upperLabel: { color: theme.ink },
      children,
    }
  })
}

// --- Tooltip + labels ------------------------------------------------------

interface TreemapParams {
  name?: string
  data?: { valueStr?: string; weightStr?: string; sector?: string }
  treePathInfo?: Array<{ name?: string }>
}

/**
 * Per-tile tooltip: name, value and weight (#53's acceptance criteria), with the
 * parent sector shown for an instrument tile so a small tile is still locatable.
 * Names are API-sourced and therefore untrusted — every one goes through
 * escapeHtml before it becomes innerHTML.
 */
export function renderTreemapTooltip(params: unknown, theme: ChartTheme): string {
  const p = params as TreemapParams
  const name = escapeHtml(p.name ?? '')
  const value = p.data?.valueStr ? formatCurrency(p.data.valueStr) : '—'
  const weight = p.data?.weightStr ? formatPercent(p.data.weightStr) : '—'
  const sector = p.data?.sector

  const row = (label: string, v: string): string =>
    `<div style="display:flex;justify-content:space-between;gap:16px"><span style="color:${theme.inkMuted}">${label}</span><span style="color:${theme.ink};font-weight:600;font-variant-numeric:tabular-nums">${v}</span></div>`

  const heading =
    sector && sector !== p.name
      ? `<div style="font-weight:600;color:${theme.ink}">${name}</div><div style="color:${theme.inkSubtle};font-size:11px;margin-bottom:2px">${escapeHtml(sector)}</div>`
      : `<div style="font-weight:600;color:${theme.ink};margin-bottom:2px">${name}</div>`

  return `<div style="font-size:12px;line-height:1.5">${heading}${row('Value', value)}${row('Weight', weight)}</div>`
}

/** Instrument tile label: `AAPL` over its weight, e.g. `AAPL\n42.10%`. */
export function treemapLeafLabel(params: unknown): string {
  const p = params as TreemapParams
  const weight = p.data?.weightStr ? formatPercent(p.data.weightStr) : ''
  return weight ? `${p.name ?? ''}\n${weight}` : `${p.name ?? ''}`
}

/** Sector header label: `Technology · 58.30%`. */
export function treemapSectorLabel(params: unknown): string {
  const p = params as TreemapParams
  const weight = p.data?.weightStr ? formatPercent(p.data.weightStr) : ''
  return weight ? `${p.name ?? ''} · ${weight}` : `${p.name ?? ''}`
}

// --- Option ----------------------------------------------------------------

/**
 * Build the treemap option. Pure: `(nodes, theme)` in, `EChartsOption` out; valid
 * (and empty) on an empty node list rather than throwing.
 *
 * Labels are `truncate`d rather than allowed to overflow their tile (dataviz:
 * a label clipped by a too-small mark is a defect) — the full name always remains
 * in the tooltip and the table twin. Sector containers carry a 22px header band;
 * the 2px `gapWidth` in the surface color is the gap between fills, which is why
 * no tile needs a border drawn around it.
 *
 * Drill-down (`nodeClick`) and `roam` are off: this is a fixed-size dashboard card
 * showing one snapshot, and a click that silently re-rooted the chart would leave
 * the reader somewhere the card's title no longer describes.
 */
export function buildSectorTreemapOption(
  nodes: readonly TreemapSectorNode[],
  theme: ChartTheme,
): EChartsOption {
  return {
    animation: false,
    backgroundColor: 'transparent',
    textStyle: { color: theme.ink },
    tooltip: {
      trigger: 'item',
      backgroundColor: theme.panel,
      borderColor: theme.line,
      textStyle: { color: theme.ink },
      formatter: (params: unknown): string => renderTreemapTooltip(params, theme),
    },
    series: [
      {
        name: 'Allocation by sector',
        type: 'treemap',
        roam: false,
        nodeClick: false,
        breadcrumb: { show: false },
        top: 4,
        left: 0,
        right: 0,
        bottom: 4,
        // Squarer tiles hold their labels better than the default ratio.
        squareRatio: 1,
        itemStyle: { gapWidth: 2, borderColor: theme.panel, borderWidth: 0 },
        label: {
          show: true,
          formatter: treemapLeafLabel,
          fontSize: 11,
          lineHeight: 14,
          overflow: 'truncate',
          ellipsis: '…',
        },
        upperLabel: {
          show: true,
          height: 22,
          formatter: treemapSectorLabel,
          fontSize: 11,
          fontWeight: 600,
          overflow: 'truncate',
          ellipsis: '…',
        },
        // levels[] is indexed by DEPTH, and depth 0 is the invisible ROOT that
        // wraps every sector — not the sectors themselves. Giving the root an
        // upperLabel (or letting it inherit the series-level one) makes ECharts
        // draw the SERIES NAME as a header band above the whole treemap, which
        // both wastes a band and duplicates the card title.
        levels: [
          {
            // Root: no header, no gap of its own.
            upperLabel: { show: false },
            itemStyle: { gapWidth: 0, borderWidth: 0 },
          },
          {
            // Sector containers: header band, plus a surface gap between sectors.
            upperLabel: { show: true },
            itemStyle: { gapWidth: 2, borderColor: theme.panel, borderWidth: 0 },
          },
          {
            // Instrument tiles inside a sector.
            itemStyle: { gapWidth: 2, borderColor: theme.panel, borderWidth: 0 },
          },
        ],
        // Nodes carry extra fields (valueStr/weightStr/sector) that ECharts passes
        // through to the tooltip untouched but does not model in its node type.
        data: nodes as unknown as TreemapSeriesOption['data'],
      },
    ],
  }
}
