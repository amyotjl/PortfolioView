/**
 * Pure sparkline geometry builder. Turns a series of numeric values into SVG
 * path strings — no Vue, no DOM, no side effects — so it is fully unit-testable
 * and cheap to render for many cards (far lighter than an ECharts instance per
 * card; the dashboard's full candlestick chart lands separately in the M6 batch).
 *
 * Coordinates use a fixed viewBox; the <svg> is stretched with a non-scaling
 * stroke, so the same geometry renders crisply at any card width.
 */

export interface SparklineGeometry {
  /** `d` for the trend line. */
  line: string
  /** `d` for the soft fill under the line (line closed down to the baseline). */
  area: string
  /** End-point of the line, for a terminal dot. */
  last: { x: number; y: number }
  width: number
  height: number
}

export interface SparklineOptions {
  width?: number
  height?: number
  /** Vertical inset so the stroke and end dot are never clipped at the extremes. */
  padding?: number
}

function round(value: number): number {
  return Math.round(value * 100) / 100
}

/**
 * Returns null when there are fewer than two points (nothing to draw) — callers
 * render an empty state instead. A flat series is centered vertically.
 */
export function buildSparkline(
  values: number[],
  options: SparklineOptions = {},
): SparklineGeometry | null {
  const width = options.width ?? 240
  const height = options.height ?? 40
  const padding = options.padding ?? 3

  const clean = values.filter((v) => Number.isFinite(v))
  if (clean.length < 2) return null

  const min = Math.min(...clean)
  const max = Math.max(...clean)
  const range = max - min
  const innerHeight = height - padding * 2
  const stepX = width / (clean.length - 1)

  const points = clean.map((value, index) => {
    const x = index * stepX
    const y = range === 0 ? height / 2 : padding + innerHeight * (1 - (value - min) / range)
    return { x: round(x), y: round(y) }
  })

  const line = points.map((p, i) => `${i === 0 ? 'M' : 'L'}${p.x} ${p.y}`).join(' ')
  const first = points[0]
  const last = points[points.length - 1]
  const area = `${line} L${last.x} ${height} L${first.x} ${height} Z`

  return { line, area, last, width, height }
}
