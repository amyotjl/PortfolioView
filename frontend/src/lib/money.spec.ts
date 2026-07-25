import { describe, expect, it } from 'vitest'
import { centsToDecimalString, centsToDollars, toCents } from './money'

describe('toCents', () => {
  it('parses the 2dp money strings the API emits', () => {
    expect(toCents('0.00')).toBe(0)
    expect(toCents('1234.56')).toBe(123_456)
    expect(toCents('1000')).toBe(100_000)
    expect(toCents('0.07')).toBe(7)
  })

  it('parses signed values (a sell/withdrawal net flow)', () => {
    expect(toCents('-500.00')).toBe(-50_000)
    expect(toCents('-0.01')).toBe(-1)
    expect(toCents('+250.50')).toBe(25_050)
  })

  it('pads a single decimal place rather than misreading it', () => {
    expect(toCents('1.5')).toBe(150)
    expect(toCents('0.5')).toBe(50)
  })

  it('rounds a third decimal place half-away-from-zero instead of truncating', () => {
    expect(toCents('1.005')).toBe(101)
    expect(toCents('1.004')).toBe(100)
    expect(toCents('-1.005')).toBe(-101)
  })

  it('returns null for anything that is not a plain decimal', () => {
    for (const bad of ['', ' ', 'n/a', 'abc', '1e3', '1.2.3', '--1', '$5', 'NaN', 'Infinity']) {
      expect(toCents(bad), bad).toBeNull()
    }
  })

  it('tolerates surrounding whitespace', () => {
    expect(toCents('  42.00 ')).toBe(4_200)
  })
})

describe('centsToDecimalString', () => {
  it('round-trips every value toCents produces', () => {
    for (const value of ['0.00', '1234.56', '-500.00', '0.07', '-0.01', '9999999.99']) {
      expect(centsToDecimalString(toCents(value) as number)).toBe(
        // toCents normalizes '+' and pads, so compare against the canonical form
        value.replace(/^\+/, ''),
      )
    }
  })

  it('always pads to exactly two decimal places', () => {
    expect(centsToDecimalString(0)).toBe('0.00')
    expect(centsToDecimalString(5)).toBe('0.05')
    expect(centsToDecimalString(50)).toBe('0.50')
    expect(centsToDecimalString(-5)).toBe('-0.05')
  })
})

describe('exact accumulation', () => {
  it('sums 2dp money with no drift, where floats would introduce it', () => {
    // 0.1 + 0.2 !== 0.3 in IEEE-754; in cents it is exactly 30.
    expect(toCents('0.10')! + toCents('0.20')!).toBe(30)
    expect(centsToDecimalString(toCents('0.10')! + toCents('0.20')!)).toBe('0.30')

    // A long running sum stays exact — the case the contribution baseline hits.
    let cents = 0
    for (let i = 0; i < 1000; i++) cents += toCents('0.07') as number
    expect(cents).toBe(70_00)
    expect(centsToDecimalString(cents)).toBe('70.00')
  })

  it('keeps a difference of two large near-equal sums exact', () => {
    // Catastrophic cancellation territory for floats.
    const value = toCents('1000000.00') as number
    const contributed = toCents('999999.99') as number
    expect(value - contributed).toBe(1)
    expect(centsToDecimalString(value - contributed)).toBe('0.01')
  })
})

describe('centsToDollars', () => {
  it('converts at the plotting boundary', () => {
    expect(centsToDollars(123_456)).toBe(1234.56)
    expect(centsToDollars(-50_000)).toBe(-500)
    expect(centsToDollars(0)).toBe(0)
  })
})
