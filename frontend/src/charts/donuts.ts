/**
 * Pure builders for the two allocation donuts (backlog #043 / #47), fed by
 * GET /allocations: by_instrument and by_sector. Sector-less instruments are
 * already bucketed server-side as "ETF / Fund", so that slice renders straight
 * through.
 *
 * Slices are colored by an ORDINAL single-hue ramp (largest = darkest), not a
 * categorical palette: rows arrive largest-first and a pie is magnitude-ordered,
 * so a lightness ramp reinforces the order, stays CVD-safe, and — unlike the
 * 8-hue categorical cap — reads cleanly with 10+ slices. Identity is carried by
 * direct labels on the larger slices, the per-slice tooltip, and the table twin
 * (never by hue alone).
 */
import type { EChartsOption } from 'echarts'
import type { Allocations } from '@/types'
import type { ChartTheme } from './theme'
import { escapeHtml, sampleRamp } from './colors'
import { formatCurrency, formatPercent } from '@/lib/format'

/** Normalized donut slice. `value` is the angle number; the raw strings feed the tooltip at full precision. */
export interface DonutRow {
  name: string
  value: number
  valueStr: string
  weightStr: string
}

export interface DonutOptions {
  /** Series name (also the aria/label context). */
  name: string
}

/** by_instrument rows; a null symbol falls back to a stable `#<id>` label. */
export function instrumentDonutRows(alloc: Allocations): DonutRow[] {
  return alloc.by_instrument.map((r) => ({
    name: r.symbol ?? `#${r.instrument_id}`,
    value: Number(r.value),
    valueStr: r.value,
    weightStr: r.weight,
  }))
}

/** by_sector rows; the sector-less "ETF / Fund" bucket is server-provided. */
export function sectorDonutRows(alloc: Allocations): DonutRow[] {
  return alloc.by_sector.map((r) => ({
    name: r.sector,
    value: Number(r.value),
    valueStr: r.value,
    weightStr: r.weight,
  }))
}

function swatch(color: string): string {
  return `<span style="display:inline-block;width:9px;height:9px;border-radius:2px;background:${color};vertical-align:middle;margin-right:6px"></span>`
}

function renderDonutTooltip(params: unknown, theme: ChartTheme): string {
  const p = params as {
    name?: string
    color?: string
    data?: { valueStr?: string; weightStr?: string }
  }
  const name = escapeHtml(p.name ?? '')
  const color = typeof p.color === 'string' ? p.color : theme.accent
  const value = p.data?.valueStr ? formatCurrency(p.data.valueStr) : '—'
  const weight = p.data?.weightStr ? formatPercent(p.data.weightStr) : '—'
  const row = (label: string, v: string): string =>
    `<div style="display:flex;justify-content:space-between;gap:16px"><span style="color:${theme.inkMuted}">${label}</span><span style="color:${theme.ink};font-weight:600;font-variant-numeric:tabular-nums">${v}</span></div>`
  return `<div style="font-size:12px;line-height:1.5"><div style="font-weight:600;color:${theme.ink};margin-bottom:2px">${swatch(color)}${name}</div>${row('Value', value)}${row('Weight', weight)}</div>`
}

function donutLabel(params: unknown): string {
  const p = params as { name?: string; data?: { weightStr?: string } }
  const weight = p.data?.weightStr ? formatPercent(p.data.weightStr) : ''
  return `${p.name ?? ''}  ${weight}`
}

/**
 * Build a donut option for a set of allocation rows. Pure. Empty rows yield a
 * valid, empty option (no crash) — the component renders a friendly empty state
 * instead of an empty chart.
 */
export function buildAllocationDonutOption(
  rows: readonly DonutRow[],
  theme: ChartTheme,
  opts: DonutOptions,
): EChartsOption {
  const colors = sampleRamp(theme.donutRamp, rows.length)
  const data = rows.map((r, i) => ({
    name: r.name,
    value: r.value,
    valueStr: r.valueStr,
    weightStr: r.weightStr,
    itemStyle: { color: colors[i] },
  }))

  return {
    animation: false,
    backgroundColor: 'transparent',
    textStyle: { color: theme.ink },
    tooltip: {
      trigger: 'item',
      backgroundColor: theme.panel,
      borderColor: theme.line,
      textStyle: { color: theme.ink },
      formatter: (params: unknown): string => renderDonutTooltip(params, theme),
    },
    series: [
      {
        name: opts.name,
        type: 'pie',
        radius: ['42%', '64%'],
        center: ['50%', '50%'],
        // Hide labels for small slices so 10+ slices stay readable; the tooltip
        // and table twin still carry every value.
        minShowLabelAngle: 12,
        avoidLabelOverlap: true,
        itemStyle: { borderColor: theme.panel, borderWidth: 2, borderRadius: 2 },
        label: { color: theme.inkMuted, formatter: donutLabel },
        labelLine: { lineStyle: { color: theme.line } },
        emphasis: { focus: 'self' },
        data,
      },
    ],
  }
}
