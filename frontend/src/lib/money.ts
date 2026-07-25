/**
 * Exact arithmetic on the API's money strings, in integer cents.
 *
 * `lib/decimal.ts` deliberately does no arithmetic — it compares unsigned decimal
 * strings digit-by-digit. That is the right tool for the sell pre-flight, but the
 * contribution-vs-growth chart has to *add*: cumulative net cash flow is a running
 * sum over the window, and growth is a difference of two large, near-equal sums.
 *
 * Money is 2dp by contract (PortfolioAllocationsSerializer and friends round to
 * cents before serializing — docs/API_SHAPES.md), so cents are a LOSSLESS integer
 * representation of every money string the API emits. Summing in integers means
 * the running total is exact rather than "exact to within 1e-13, which happens to
 * round the same way" — no reasoning about accumulated float error, and the
 * derived figures can be handed back to the decimal-string formatters at full
 * precision, exactly like values that came straight off the wire.
 *
 * Cents stay well inside Number.MAX_SAFE_INTEGER (9e15 cents = $90 trillion), so
 * plain numbers are safe here and no BigInt is needed.
 */

/** Optional sign, integer part, optional fraction. Rejects exponent notation. */
const MONEY = /^([+-]?)(\d+)(?:\.(\d+))?$/

/**
 * Parse a money string to exact integer cents, or null if it is not a plain
 * decimal. A third+ decimal place is rounded half-away-from-zero rather than
 * truncated — it should not occur (the API rounds to cents) but silently dropping
 * a half-cent is worse than rounding it.
 */
export function toCents(value: string): number | null {
  const match = MONEY.exec(value.trim())
  if (!match) return null

  const [, sign, intDigits, fracDigits = ''] = match
  const cents = Number(intDigits) * 100 + Number(fracDigits.slice(0, 2).padEnd(2, '0'))
  const thirdDigit = fracDigits.charAt(2)
  const rounded = thirdDigit !== '' && Number(thirdDigit) >= 5 ? cents + 1 : cents
  return sign === '-' ? -rounded : rounded
}

/**
 * Integer cents back to a signed 2dp decimal string — the same shape the API
 * speaks, so it feeds `formatCurrency` without ever touching a float.
 */
export function centsToDecimalString(cents: number): string {
  const sign = cents < 0 ? '-' : ''
  const abs = Math.abs(cents)
  const whole = Math.floor(abs / 100)
  const frac = abs % 100
  return `${sign}${whole}.${String(frac).padStart(2, '0')}`
}

/**
 * Cents to a plotting number (dollars). This is the chart boundary — pixels don't
 * need exact decimals (see the note atop charts/candles.ts).
 */
export function centsToDollars(cents: number): number {
  return cents / 100
}
