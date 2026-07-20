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
   * Ordinal ramp for allocation donuts (dark -> light = largest -> smallest
   * slice). These are the documented, validator-passing blue ordinal steps
   * (dataviz `palette.md` § Sequential hue), hue-aligned with the app's
   * trading-blue accent. Trimmed to the contrast-safe sub-range for each mode.
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
  // Blue ordinal steps 600 -> 250 (light-end clears the 2:1 ordinal floor).
  donutRamp: ['#184f95', '#256abf', '#2a78d6', '#3987e5', '#5598e7', '#6da7ec', '#86b6ef'],
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
  // Blue steps stepped up for the dark surface (all clear 3:1 on the dark panel).
  donutRamp: ['#3987e5', '#5598e7', '#6da7ec', '#86b6ef', '#9ec5f4', '#b7d3f6', '#cde2fb'],
}

/** Resolve the mirrored chart theme for a theme-store value. Pure. */
export function chartTheme(theme: Theme): ChartTheme {
  return theme === 'dark' ? DARK_CHART_THEME : LIGHT_CHART_THEME
}
