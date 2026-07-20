import { describe, expect, it } from 'vitest'
import { formatCurrency, formatPercent, formatSignedPercent } from './format'

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

describe('formatPercent', () => {
  it('turns a fraction into a percent with two fraction digits', () => {
    expect(formatPercent('0.234567')).toBe('23.46%')
  })
})

describe('formatSignedPercent', () => {
  it('shows an explicit sign for gains and losses but not for zero', () => {
    expect(formatSignedPercent(0.1234)).toBe('+12.34%')
    expect(formatSignedPercent(-0.05)).toBe('-5.00%')
    expect(formatSignedPercent(0)).toBe('0.00%')
  })
})
