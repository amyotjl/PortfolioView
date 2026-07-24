import type { RangePreset } from '@/stores/range-preset'
import type { CandlesRange } from '@/composables/usePortfolioCandles'

/**
 * Map a date-range preset to a `{ from, to }` candles window. Pure and
 * deterministic (pass a reference date; defaults to now) so it unit-tests
 * without mocking the clock.
 *
 * Only `from` is set. `to` is intentionally omitted so the backend uses its own
 * last trading day (America/New_York) as the upper bound — deriving `to` from
 * the client clock could clip the final day for a viewer whose local date trails
 * ET. `ALL` sends neither bound (inception -> last trading day). Dates are built
 * from and read as LOCAL components, so a window floor never drifts a day.
 */
const PRESET_MONTHS: Record<Exclude<RangePreset, 'YTD' | 'ALL'>, number> = {
  '1M': 1,
  '3M': 3,
  '6M': 6,
  '1Y': 12,
  '5Y': 60,
}

function pad(n: number): string {
  return String(n).padStart(2, '0')
}

function isoDate(d: Date): string {
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`
}

export function presetToRange(preset: RangePreset, reference: Date = new Date()): CandlesRange {
  if (preset === 'ALL') return {}
  if (preset === 'YTD') {
    return { from: isoDate(new Date(reference.getFullYear(), 0, 1)) }
  }
  const from = new Date(reference)
  from.setMonth(from.getMonth() - PRESET_MONTHS[preset])
  return { from: isoDate(from) }
}
