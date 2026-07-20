/**
 * Shared display formatters (Intl-based). Kept as plain, pure utilities per the
 * vue-best-practices "keep utilities as utilities" guidance — no reactivity is
 * needed, and pure functions are trivially unit-testable.
 *
 * MONEY/PERCENT PRECISION: the backend serializes BigDecimal as JSON *strings*
 * (docs/PLAN.md). `Intl.NumberFormat.format()` accepts string arguments at
 * runtime (ECMA-402) and formats them with FULL precision — so we pass the raw
 * decimal string straight through and never route money through IEEE-754. The
 * TypeScript lib types lag the spec (they only list number|bigint), so the
 * format call is widened deliberately in `formatWith`.
 */

type IntlValue = number | bigint | string

const currencyFormatter = new Intl.NumberFormat('en-US', {
  style: 'currency',
  currency: 'USD',
  minimumFractionDigits: 2,
  maximumFractionDigits: 2,
})

const percentFormatter = new Intl.NumberFormat('en-US', {
  style: 'percent',
  minimumFractionDigits: 2,
  maximumFractionDigits: 2,
})

const signedPercentFormatter = new Intl.NumberFormat('en-US', {
  style: 'percent',
  minimumFractionDigits: 2,
  maximumFractionDigits: 2,
  signDisplay: 'exceptZero',
})

const dateFormatter = new Intl.DateTimeFormat('en-US', {
  year: 'numeric',
  month: 'short',
  day: 'numeric',
  // Trading days are calendar dates in America/New_York; pin the zone so a
  // 'YYYY-MM-DD' never renders as the previous day in a western timezone.
  timeZone: 'America/New_York',
})

function formatWith(formatter: Intl.NumberFormat, value: IntlValue): string {
  return (formatter.format as (v: IntlValue) => string)(value)
}

/** USD currency, 2dp: `12345.67` / `'12345.67'` -> `'$12,345.67'`. */
export function formatCurrency(value: IntlValue): string {
  return formatWith(currencyFormatter, value)
}

/** Fraction -> percent, 2dp: `0.234567` / `'0.234567'` -> `'23.46%'`. */
export function formatPercent(fraction: IntlValue): string {
  return formatWith(percentFormatter, fraction)
}

/** Fraction -> signed percent: `0.1234` -> `'+12.34%'`, `-0.05` -> `'-5.00%'`, `0` -> `'0.00%'`. */
export function formatSignedPercent(fraction: IntlValue): string {
  return formatWith(signedPercentFormatter, fraction)
}

/** ISO date/datetime -> `'Jul 17, 2026'` in America/New_York. */
export function formatDate(iso: string): string {
  const dateOnly = /^\d{4}-\d{2}-\d{2}$/.test(iso)
  // For a bare date, anchor at midday UTC so the ET calendar day is unambiguous.
  const date = dateOnly ? new Date(`${iso}T12:00:00Z`) : new Date(iso)
  return dateFormatter.format(date)
}
