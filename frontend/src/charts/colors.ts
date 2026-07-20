/**
 * Pure color + string helpers for the chart builders. No Vue, no DOM.
 */

/**
 * Escape a string for safe interpolation into an ECharts tooltip, whose string
 * return value is assigned as innerHTML. Series and category names (tickers,
 * sector names, benchmark symbols) originate from the API and are therefore
 * untrusted — never concatenate them raw. (dataviz `interaction.md`: "Labels are
 * untrusted data.")
 */
export function escapeHtml(value: string): string {
  return value
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;')
}

function clampByte(n: number): number {
  return Math.max(0, Math.min(255, Math.round(n)))
}

interface Rgb {
  r: number
  g: number
  b: number
}

/** Parse `#rrggbb` (case-insensitive) into channels. Throws on malformed input. */
export function hexToRgb(hex: string): Rgb {
  const match = /^#?([0-9a-fA-F]{6})$/.exec(hex.trim())
  if (!match) throw new Error(`Not a #rrggbb color: ${hex}`)
  const int = parseInt(match[1], 16)
  return { r: (int >> 16) & 0xff, g: (int >> 8) & 0xff, b: int & 0xff }
}

function rgbToHex({ r, g, b }: Rgb): string {
  const hex = (clampByte(r) << 16) | (clampByte(g) << 8) | clampByte(b)
  return `#${hex.toString(16).padStart(6, '0')}`
}

/** Linear sRGB interpolation between two `#rrggbb` colors (t in [0,1]). */
export function mixHex(from: string, to: string, t: number): string {
  const a = hexToRgb(from)
  const b = hexToRgb(to)
  return rgbToHex({
    r: a.r + (b.r - a.r) * t,
    g: a.g + (b.g - a.g) * t,
    b: a.b + (b.b - a.b) * t,
  })
}

/**
 * Sample `count` colors evenly across an ordinal ramp of stops. Index 0 maps to
 * the first stop (darkest = largest slice), index `count-1` to the last stop
 * (lightest = smallest slice); intermediate slots are interpolated. Handles more
 * slices than stops (10+ allocation slices) by interpolating between neighbours,
 * so the ring stays monotone in lightness and never cycles a hue.
 */
export function sampleRamp(stops: readonly string[], count: number): string[] {
  if (count <= 0 || stops.length === 0) return []
  if (count === 1) return [stops[0]]
  const lastStop = stops.length - 1
  const out: string[] = []
  for (let i = 0; i < count; i++) {
    const pos = (i / (count - 1)) * lastStop
    const lo = Math.floor(pos)
    const hi = Math.min(lo + 1, lastStop)
    out.push(mixHex(stops[lo], stops[hi], pos - lo))
  }
  return out
}
