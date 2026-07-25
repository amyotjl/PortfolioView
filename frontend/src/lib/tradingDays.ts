/**
 * Calendar-date helpers for the transaction form (docs/PLAN.md § Frontend:
 * "Weekend-dated transactions allowed — UI copy states they take effect the
 * next trading day").
 *
 * TIMEZONE: a trading day is a calendar date in America/New_York, never an
 * instant (same reasoning as `IsoDate` in types/common.ts and the pinned zone in
 * lib/format.ts). Every function here takes and returns bare `YYYY-MM-DD`
 * strings and does its arithmetic at midday UTC, which lands on the same
 * calendar date in ET (UTC-4/-5) for every date in the year — so no date ever
 * slips a day for a user in a western timezone.
 *
 * HOLIDAYS ARE DELIBERATELY NOT MODELLED. The exchange holiday calendar lives
 * server-side (`Trading::Calendar`, built from real price history); duplicating
 * a hardcoded list here would rot and start disagreeing with the server. So we
 * detect only the part the client can know for certain — Saturday and Sunday —
 * and word the notice so it stays true when a holiday also intervenes ("the
 * next trading day", never a specific promised date).
 */

const WEEKDAY_NAMES = [
  'Sunday',
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
] as const

const ISO_DATE = /^\d{4}-\d{2}-\d{2}$/

/** Anchor a bare ISO date at midday UTC so its ET calendar day is unambiguous. */
function atMiddayUtc(iso: string): Date | null {
  if (!ISO_DATE.test(iso)) return null
  const date = new Date(`${iso}T12:00:00Z`)
  return Number.isNaN(date.getTime()) ? null : date
}

/** `'2026-07-25'` -> `'Saturday'`; null for a malformed or invalid date. */
export function weekdayName(iso: string): string | null {
  const date = atMiddayUtc(iso)
  return date ? WEEKDAY_NAMES[date.getUTCDay()] : null
}

/** True only for Saturday/Sunday. Holidays are a server concern — see the module note. */
export function isWeekend(iso: string): boolean {
  const date = atMiddayUtc(iso)
  if (!date) return false
  const day = date.getUTCDay()
  return day === 0 || day === 6
}

/**
 * Copy for the form when the chosen date is a day the market is certainly shut,
 * or null when it's an ordinary weekday. The transaction is still accepted —
 * this explains what will happen, it is not a validation error.
 *
 * Intentionally names no specific effective date: the server resolves that
 * against the real trading calendar, and a Monday holiday would make any date
 * we guessed here wrong.
 */
export function marketClosedNotice(iso: string): string | null {
  if (!isWeekend(iso)) return null
  const day = weekdayName(iso)
  return `${day} is not a trading day. The transaction is recorded on this date and takes effect on the next trading day.`
}

/** Today as `YYYY-MM-DD` in America/New_York — the form's default executed_on. */
export function todayIso(now: Date = new Date()): string {
  // 'en-CA' formats as YYYY-MM-DD, so the ET calendar date falls out directly
  // without any manual offset arithmetic.
  return new Intl.DateTimeFormat('en-CA', {
    timeZone: 'America/New_York',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
  }).format(now)
}

/**
 * `Date` <-> ISO bridges for PrimeVue DatePicker, whose v-model is a `Date`.
 * The Date is constructed in LOCAL time at midnight so the picker highlights
 * the intended day in the user's own calendar grid, and read back via its local
 * getters — round-tripping the same calendar date regardless of timezone.
 */
export function isoToPickerDate(iso: string | null | undefined): Date | null {
  if (!iso || !ISO_DATE.test(iso)) return null
  const [year, month, day] = iso.split('-').map(Number)
  const date = new Date(year, month - 1, day)
  return Number.isNaN(date.getTime()) ? null : date
}

export function pickerDateToIso(date: Date | null | undefined): string | null {
  if (!date || Number.isNaN(date.getTime())) return null
  const year = String(date.getFullYear()).padStart(4, '0')
  const month = String(date.getMonth() + 1).padStart(2, '0')
  const day = String(date.getDate()).padStart(2, '0')
  return `${year}-${month}-${day}`
}
