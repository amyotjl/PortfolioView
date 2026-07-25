import { describe, expect, it } from 'vitest'
import { compareDecimal, decimalGreaterThan, isDecimalZero } from './decimal'

describe('compareDecimal', () => {
  it('orders by integer magnitude regardless of digit count', () => {
    expect(compareDecimal('9', '10')).toBe(-1)
    expect(compareDecimal('10', '9')).toBe(1)
    expect(compareDecimal('100', '99.99')).toBe(1)
  })

  it('treats differing representations of the same value as equal', () => {
    expect(compareDecimal('1', '1.0')).toBe(0)
    expect(compareDecimal('1.50', '1.5')).toBe(0)
    expect(compareDecimal('007', '7')).toBe(0)
    expect(compareDecimal('0.5', '.5')).toBe(0)
    expect(compareDecimal('0', '0.000')).toBe(0)
  })

  it('compares fractions by value, not by string length', () => {
    // '9' > '10' lexically, so a naive string compare fails this.
    expect(compareDecimal('0.9', '0.10')).toBe(1)
    expect(compareDecimal('0.10', '0.9')).toBe(-1)
  })

  it('distinguishes values a float would collapse', () => {
    // The canonical IEEE-754 case: 0.1 + 0.2 === 0.30000000000000004.
    expect(compareDecimal('0.30000000000000004', '0.3')).toBe(1)
    // Beyond 2^53, floats step in 2s and these two would compare equal.
    expect(compareDecimal('9007199254740993', '9007199254740992')).toBe(1)
    // 8dp share precision at a large magnitude — representable in numeric(20,8).
    expect(compareDecimal('12345678901.00000002', '12345678901.00000001')).toBe(1)
  })

  it('returns null for anything that is not a plain unsigned decimal', () => {
    for (const bad of ['', ' ', 'abc', '1e3', '-1', '+1', '1.2.3', '1,000', 'NaN', 'Infinity']) {
      expect(compareDecimal(bad, '1'), bad).toBeNull()
      expect(compareDecimal('1', bad), bad).toBeNull()
    }
  })

  it('tolerates surrounding whitespace', () => {
    expect(compareDecimal(' 1.5 ', '1.5')).toBe(0)
  })
})

describe('decimalGreaterThan', () => {
  it('is strict — equal values are not greater', () => {
    expect(decimalGreaterThan('2', '1')).toBe(true)
    expect(decimalGreaterThan('1', '2')).toBe(false)
    expect(decimalGreaterThan('1.0', '1')).toBe(false)
  })

  it('is false (never true) when either side is unparseable', () => {
    // The sell pre-flight reads this as "no warning", which is the safe
    // direction: the server's replay is the real guard.
    expect(decimalGreaterThan('abc', '1')).toBe(false)
    expect(decimalGreaterThan('5', 'abc')).toBe(false)
  })
})

describe('isDecimalZero', () => {
  it('recognizes every spelling of zero', () => {
    for (const zero of ['0', '0.0', '00.000', '.0', '0.00000000']) {
      expect(isDecimalZero(zero), zero).toBe(true)
    }
  })

  it('is false for any nonzero value, however small', () => {
    expect(isDecimalZero('0.00000001')).toBe(false)
    expect(isDecimalZero('1')).toBe(false)
  })

  it('is false for unparseable input rather than defaulting to zero', () => {
    expect(isDecimalZero('abc')).toBe(false)
    expect(isDecimalZero('')).toBe(false)
  })
})
