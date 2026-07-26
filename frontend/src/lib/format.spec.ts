import { describe, expect, it } from 'vitest'
import {
  formatCurrency,
  formatDate,
  formatDateTime,
  formatPercent,
  formatSignedPercent,
} from './format'

describe('formatCurrency', () => {
  it('formats a number as USD with two fraction digits', () => {
    expect(formatCurrency(12345.67)).toBe('$12,345.67')
  })

  it('formats a decimal STRING without precision loss', () => {
    // 16 significant digits — not exactly representable as an IEEE-754 number,
    // so this proves money strings are passed through to Intl, never parseFloat'd.
    expect(formatCurrency('12345678901234.56')).toBe('$12,345,678,901,234.56')
  })

  it('formats zero', () => {
    expect(formatCurrency('0')).toBe('$0.00')
  })
})

describe('formatCurrency — negative and large string inputs', () => {
  it('formats a negative decimal string', () => {
    expect(formatCurrency('-250.00')).toBe('-$250.00')
  })

  it('keeps trailing precision digits that a float would round away', () => {
    // 0.1 + 0.2 is 0.30000000000000004 as a float; the string path is exact.
    expect(formatCurrency('0.30')).toBe('$0.30')
    expect(formatCurrency('9007199254740993.99')).toBe('$9,007,199,254,740,993.99')
  })
})

describe('formatPercent', () => {
  it('turns a fraction into a percent with two fraction digits', () => {
    expect(formatPercent('0.234567')).toBe('23.46%')
  })

  it('formats a 6dp fraction from /summary and an 8dp drawdown fraction', () => {
    // Percentages arrive as fractions and are rendered ×100 by the formatter.
    expect(formatPercent('0.084567')).toBe('8.46%')
    expect(formatPercent('-0.08340000')).toBe('-8.34%')
    expect(formatPercent('0')).toBe('0.00%')
  })
})

describe('formatSignedPercent', () => {
  it('shows an explicit sign for gains and losses but not for zero', () => {
    expect(formatSignedPercent(0.1234)).toBe('+12.34%')
    expect(formatSignedPercent(-0.05)).toBe('-5.00%')
    expect(formatSignedPercent(0)).toBe('0.00%')
  })

  it('accepts decimal STRINGS as well as numbers', () => {
    expect(formatSignedPercent('0.234567')).toBe('+23.46%')
    expect(formatSignedPercent('-0.0834')).toBe('-8.34%')
  })
})

describe('formatDate', () => {
  it('formats a bare ISO calendar date in America/New_York', () => {
    expect(formatDate('2026-01-06')).toBe('Jan 6, 2026')
    expect(formatDate('2026-07-19')).toBe('Jul 19, 2026')
  })

  it('does not shift a calendar date backwards a day', () => {
    // The trading-day bug this guards: a bare 'YYYY-MM-DD' naively parsed as UTC
    // midnight renders as the PREVIOUS day in any western timezone.
    expect(formatDate('2026-01-01')).toBe('Jan 1, 2026')
    expect(formatDate('2026-12-31')).toBe('Dec 31, 2026')
  })

  it('formats a full ISO-8601 UTC timestamp', () => {
    // 2026-01-06T02:00:00Z is still Jan 5 in America/New_York (21:00 ET).
    expect(formatDate('2026-01-06T02:00:00Z')).toBe('Jan 5, 2026')
  })
})

describe('formatDateTime', () => {
  it('renders a UTC timestamp as an ET wall clock, zone spelled out', () => {
    expect(formatDateTime('2026-07-26T17:42:02Z')).toBe('Jul 26, 1:42 PM EDT')
  })

  it('follows the ET offset across the DST boundary, and back a day when it must', () => {
    // 02:00Z on Jan 6 is 21:00 on Jan 5 in EST — a naive UTC render would name
    // the wrong day AND the wrong zone.
    expect(formatDateTime('2026-01-06T02:00:00Z')).toBe('Jan 5, 9:00 PM EST')
  })

  it('echoes an unparseable timestamp instead of throwing', () => {
    // Intl throws a RangeError on an Invalid Date; a malformed value must degrade
    // to ugly copy, never to a blank card.
    expect(formatDateTime('not-a-timestamp')).toBe('not-a-timestamp')
  })
})
