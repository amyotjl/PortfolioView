/**
 * Exact comparison for the unsigned decimal STRINGS the API speaks
 * (docs/API_SHAPES.md: money/shares are JSON strings, BigDecimal end-to-end).
 *
 * The sell pre-flight has to answer "are these shares more than the position?".
 * Doing that with `parseFloat(a) > parseFloat(b)` would reintroduce exactly the
 * IEEE-754 error the string contract exists to prevent — and at 8dp share
 * precision it is reachable, not theoretical: parseFloat('0.30000000000000004')
 * and parseFloat('0.3') are the classic case, and a position of
 * `10.00000001` vs `10.00000002` shares is representable in the column but not
 * distinguishable in a float once values get large.
 *
 * So we compare digit-by-digit instead: align the integer parts by length, then
 * the fraction parts by right-padding. No arithmetic, no rounding, no bigint
 * conversion of an unbounded input.
 */

const DECIMAL = /^(?:\d+(?:\.\d*)?|\.\d+)$/

function stripLeadingZeros(digits: string): string {
  const trimmed = digits.replace(/^0+/, '')
  return trimmed === '' ? '0' : trimmed
}

/** Split into normalized [integerDigits, fractionDigits]; null if not a plain decimal. */
function parts(value: string): [string, string] | null {
  const trimmed = value.trim()
  if (!DECIMAL.test(trimmed)) return null
  const [intPart = '', fracPart = ''] = trimmed.split('.')
  return [stripLeadingZeros(intPart || '0'), fracPart.replace(/0+$/, '')]
}

/**
 * -1 / 0 / 1 for a < b, a === b, a > b. Returns null when either side is not a
 * plain unsigned decimal, so callers must decide what an unparseable value means
 * rather than silently treating it as zero.
 */
export function compareDecimal(a: string, b: string): -1 | 0 | 1 | null {
  const left = parts(a)
  const right = parts(b)
  if (!left || !right) return null

  const [leftInt, leftFrac] = left
  const [rightInt, rightFrac] = right

  // Longer integer part (already zero-stripped) is unambiguously larger.
  if (leftInt.length !== rightInt.length) return leftInt.length > rightInt.length ? 1 : -1
  if (leftInt !== rightInt) return leftInt > rightInt ? 1 : -1

  // Equal integer parts: right-pad fractions to a common width and compare as
  // digit strings, which is a correct ordering once both are the same length.
  const width = Math.max(leftFrac.length, rightFrac.length)
  const leftPadded = leftFrac.padEnd(width, '0')
  const rightPadded = rightFrac.padEnd(width, '0')
  if (leftPadded === rightPadded) return 0
  return leftPadded > rightPadded ? 1 : -1
}

/** True when `a` is strictly greater than `b`; false if either is unparseable. */
export function decimalGreaterThan(a: string, b: string): boolean {
  return compareDecimal(a, b) === 1
}

/** True when the value parses and holds no nonzero digit. */
export function isDecimalZero(value: string): boolean {
  const split = parts(value)
  if (!split) return false
  return !/[1-9]/.test(split[0] + split[1])
}
