import { describe, expect, it } from 'vitest'
import {
  compareDecimal,
  decimalGreaterThan,
  isDecimalZero,
  sellPreflightMessage,
} from './decimal'

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

describe('sellPreflightMessage', () => {
  const base = {
    symbol: 'AAPL',
    requestedShares: '10',
    heldShares: '4',
    on: '2026-07-20',
    effectiveOn: '2026-07-20',
  }

  it('is null when the position covers the sell', () => {
    expect(sellPreflightMessage({ ...base, requestedShares: '4' })).toBeNull()
    expect(sellPreflightMessage({ ...base, requestedShares: '3' })).toBeNull()
    expect(sellPreflightMessage({ ...base, requestedShares: '4.0', heldShares: '4' })).toBeNull()
  })

  it('warns about rejection when the position is current for that date', () => {
    const message = sellPreflightMessage(base) ?? ''
    expect(message).toContain('holds 4 shares of AAPL on 2026-07-20')
    expect(message).toContain('may be rejected')
  })

  it('says "no shares" rather than "0 shares" for a flat position', () => {
    const message = sellPreflightMessage({ ...base, heldShares: '0.0' }) ?? ''
    expect(message).toContain('no shares')
    expect(message).not.toContain('0.0 shares')
  })

  it('does NOT claim rejection when the position figure lags the sell date', () => {
    // The live case: /holdings is quantized to the last trading day <= as_of, so
    // shares bought after the newest cached close are invisible to it. Claiming a
    // shortfall here would be a false alarm.
    const message = sellPreflightMessage({ ...base, effectiveOn: '2026-07-16' }) ?? ''
    expect(message).toContain('As of 2026-07-16')
    expect(message).toContain('4 shares')
    expect(message).not.toContain('may be rejected')
    expect(message).toContain('server checks the full history')
  })

  it('treats an unknown effective date as current rather than inventing one', () => {
    const message = sellPreflightMessage({ ...base, effectiveOn: null }) ?? ''
    expect(message).toContain('may be rejected')
    expect(message).not.toContain('As of')
  })

  it('is null when either decimal is unparseable (never a bogus warning)', () => {
    expect(sellPreflightMessage({ ...base, requestedShares: 'abc' })).toBeNull()
    expect(sellPreflightMessage({ ...base, heldShares: 'abc' })).toBeNull()
    expect(sellPreflightMessage({ ...base, requestedShares: '' })).toBeNull()
  })

  it('is null when the form is not filled in enough to say anything', () => {
    expect(sellPreflightMessage({ ...base, symbol: '' })).toBeNull()
    expect(sellPreflightMessage({ ...base, on: '' })).toBeNull()
  })

  it('uses exact decimal comparison, not float, to decide whether to warn', () => {
    // A float compare would call these equal and stay silent.
    expect(
      sellPreflightMessage({
        ...base,
        requestedShares: '12345678901.00000002',
        heldShares: '12345678901.00000001',
      }),
    ).not.toBeNull()
  })
})
