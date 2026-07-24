/**
 * Chart theme tokens, mirrored from the `--pv-*` custom properties in
 * `src/assets/main.css`.
 *
 * The chart option builders are PURE and DOM-free (so they unit-test without a
 * browser). ECharts can't read CSS custom properties itself, and reading them
 * via `getComputedStyle` inside a builder would (a) require a DOM and (b) race
 * the theme-flip that stamps `data-theme` on <html>. So instead of reading the
 * live cascade we mirror the same palette here, keyed by theme name, and let the
 * component pass the resolved theme into the builder. `useThemeStore().theme`
 * drives which one is chosen, so charts re-render on a theme flip.
 *
 * Keep these values in sync with `main.css` — they are the same design tokens.
 * `up`/`down` stay reserved for data polarity (candle up/down, flow sign,
 * drawdown), never chrome, exactly as the CSS comment states.
 */
import type { Theme } from '@/stores/theme'

export interface ChartTheme {
  /** Chart surface (matches the card panel the chart sits on). */
  panel: string
  panelHi: string
  /** Primary text. */
  ink: string
  /** Axis titles / secondary text. */
  inkMuted: string
  /** Axis labels / muted text. */
  inkSubtle: string
  /** Hairline gridlines / axis rules. */
  line: string
  lineStrong: string
  /** Single accent (benchmark line). */
  accent: string
  /** Reserved data-polarity colors. */
  up: string
  down: string
  warn: string
  /**
   * Ordinal ramp for the allocation donuts: index 0 is the LARGEST slice and is
   * always the most prominent step against that mode's surface (darkest on
   * light, lightest on dark), running to the least prominent for the smallest
   * slice. Steps come from the documented blue sequential ramp (dataviz
   * `palette.md` § Sequential hue), hue-aligned with the app's trading-blue
   * accent.
   *
   * The stop count is CHOSEN, not guessed: the ordinal checks require monotone
   * lightness, adjacent OKLCH dL >= 0.06, and >= 2:1 contrast for the
   * surface-nearest step. Enumerating every subset of the documented ramp shows
   * a single hue cannot hold more than 5 stops at that dL floor on the light
   * surface, so both modes use 5 (light min dL 0.095, nearest contrast 2.50:1;
   * dark min dL 0.095, nearest contrast 2.23:1 — both PASS).
   *
   * With more slices than stops, `sampleRamp` interpolates, so adjacent slices
   * in a 10+ slice donut necessarily sit below the dL floor — unavoidable for
   * any single-hue ring past ~5 classes. Identity there does not rest on hue:
   * each slice carries a 2px surface-colored gap, labels are shown only for
   * slices big enough to hold them, and every slice's exact value and weight is
   * in the per-slice tooltip and the always-available table twin.
   */
  donutRamp: readonly string[]
}

/** Light theme — mirrors `:root` / `[data-theme='light']` in main.css. */
export const LIGHT_CHART_THEME: ChartTheme = {
  panel: '#ffffff',
  panelHi: '#eceff4',
  ink: '#10131a',
  inkMuted: '#586173',
  inkSubtle: '#858d9c',
  line: '#e1e5ec',
  lineStrong: '#c9d0da',
  accent: '#2f62f5',
  up: '#12885a',
  down: '#cf3a3a',
  warn: '#b5790a',
  // Blue steps 700,600,500,400,300 — darkest (largest slice) to lightest.
  donutRamp: ['#0d366b', '#184f95', '#256abf', '#3987e5', '#6da7ec'],
}

/** Dark theme — mirrors `[data-theme='dark']` in main.css. */
export const DARK_CHART_THEME: ChartTheme = {
  panel: '#12161f',
  panelHi: '#1a2030',
  ink: '#e9edf4',
  inkMuted: '#99a2b3',
  inkSubtle: '#697386',
  line: '#232a37',
  lineStrong: '#344054',
  accent: '#5385ff',
  up: '#34c98a',
  down: '#ff5c5c',
  warn: '#e0a92e',
  // Blue steps 200,300,400,500,600 — lightest (largest slice, most prominent on
  // dark) to darkest. Selected for the dark surface, not flipped from light.
  donutRamp: ['#9ec5f4', '#6da7ec', '#3987e5', '#256abf', '#184f95'],
}

/** Resolve the mirrored chart theme for a theme-store value. Pure. */
export function chartTheme(theme: Theme): ChartTheme {
  return theme === 'dark' ? DARK_CHART_THEME : LIGHT_CHART_THEME
}
