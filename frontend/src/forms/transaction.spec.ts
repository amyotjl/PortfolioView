import { describe, expect, it } from 'vitest'
import {
  emptyTransactionForm,
  transactionFormSchema,
  type TransactionFormValues,
} from './transaction'

function valid(overrides: Partial<Record<keyof TransactionFormValues, unknown>> = {}) {
  return {
    symbol: 'AAPL',
    side: 'buy',
    kind: 'normal',
    shares: '10',
    price: '150.25',
    fees: '0',
    executed_on: '2026-07-24',
    notes: null,
    ...overrides,
  }
}

/** First error message for a field, or undefined when the field validated. */
function errorFor(input: unknown, field: keyof TransactionFormValues): string | undefined {
  const result = transactionFormSchema.safeParse(input)
  if (result.success) return undefined
  return result.error.issues.find((issue) => issue.path[0] === field)?.message
}

describe('transactionFormSchema', () => {
  it('accepts a well-formed buy', () => {
    const result = transactionFormSchema.safeParse(valid())
    expect(result.success).toBe(true)
  })

  it('uppercases the symbol so the server resolves it consistently', () => {
    const result = transactionFormSchema.parse(valid({ symbol: 'aapl' }))
    expect(result.symbol).toBe('AAPL')
  })

  it('trims an empty notes field to null rather than sending an empty string', () => {
    expect(transactionFormSchema.parse(valid({ notes: '   ' })).notes).toBeNull()
    expect(transactionFormSchema.parse(valid({ notes: '' })).notes).toBeNull()
    expect(transactionFormSchema.parse(valid({ notes: '  hi  ' })).notes).toBe('hi')
  })

  describe('decimal fields keep their string precision', () => {
    it('does not round or reformat the value it accepts', () => {
      const result = transactionFormSchema.parse(
        valid({ shares: '0.00000001', price: '1234.567890' }),
      )
      // Byte-identical to what was typed — no float round-trip anywhere.
      expect(result.shares).toBe('0.00000001')
      expect(result.price).toBe('1234.567890')
    })

    it('accepts a leading-dot decimal', () => {
      expect(transactionFormSchema.safeParse(valid({ shares: '.5' })).success).toBe(true)
    })

    it('rejects non-numeric and exponent/sign forms', () => {
      for (const bad of ['abc', '1e3', '-1', '+1', '1,000', '1.2.3', '']) {
        expect(errorFor(valid({ shares: bad }), 'shares'), bad).toBeDefined()
      }
    })
  })

  describe('scale limits mirror the numeric() column precision', () => {
    it('allows shares to 8dp and rejects 9', () => {
      expect(transactionFormSchema.safeParse(valid({ shares: '1.12345678' })).success).toBe(true)
      expect(errorFor(valid({ shares: '1.123456789' }), 'shares')).toContain('8 decimal places')
    })

    it('allows price to 6dp and rejects 7', () => {
      expect(transactionFormSchema.safeParse(valid({ price: '1.123456' })).success).toBe(true)
      expect(errorFor(valid({ price: '1.1234567' }), 'price')).toContain('6 decimal places')
    })

    it('allows fees to 2dp and rejects 3', () => {
      expect(transactionFormSchema.safeParse(valid({ fees: '1.99' })).success).toBe(true)
      expect(errorFor(valid({ fees: '1.999' }), 'fees')).toContain('2 decimal places')
    })
  })

  describe('sign rules mirror the CHECK constraints', () => {
    it('rejects zero shares and zero price (shares > 0, price > 0)', () => {
      expect(errorFor(valid({ shares: '0' }), 'shares')).toContain('greater than zero')
      expect(errorFor(valid({ shares: '0.00000000' }), 'shares')).toContain('greater than zero')
      expect(errorFor(valid({ price: '0.000000' }), 'price')).toContain('greater than zero')
    })

    it('allows zero fees (fees >= 0)', () => {
      expect(transactionFormSchema.safeParse(valid({ fees: '0' })).success).toBe(true)
      expect(transactionFormSchema.safeParse(valid({ fees: '0.00' })).success).toBe(true)
    })
  })

  describe('enum and date fields', () => {
    it('accepts both sides and both kinds', () => {
      for (const side of ['buy', 'sell']) {
        expect(transactionFormSchema.safeParse(valid({ side })).success, side).toBe(true)
      }
      for (const kind of ['normal', 'dividend_reinvestment']) {
        expect(transactionFormSchema.safeParse(valid({ kind })).success, kind).toBe(true)
      }
    })

    it('rejects an unknown side', () => {
      expect(transactionFormSchema.safeParse(valid({ side: 'short' })).success).toBe(false)
    })

    it('requires an ISO YYYY-MM-DD date', () => {
      for (const bad of ['2026-7-4', '07/04/2026', '20260704', '']) {
        expect(errorFor(valid({ executed_on: bad }), 'executed_on'), bad).toBeDefined()
      }
    })

    it('accepts a weekend date — the server decides the effective trading day', () => {
      // 2026-07-25 is a Saturday. Deliberately NOT a validation error (#49 AC).
      expect(transactionFormSchema.safeParse(valid({ executed_on: '2026-07-25' })).success).toBe(
        true,
      )
    })
  })

  it('does not model the no-short-position rule (only the server can decide it)', () => {
    // A sell of more than any plausible holding still passes client validation:
    // the rule needs a split-adjusted replay of the whole timeline, so it is
    // enforced by the server's 422 under `base`, not here.
    expect(
      transactionFormSchema.safeParse(valid({ side: 'sell', shares: '999999999' })).success,
    ).toBe(true)
  })
})

describe('emptyTransactionForm', () => {
  it('defaults to a normal buy on the given date with fees zeroed', () => {
    expect(emptyTransactionForm('2026-07-24')).toEqual({
      symbol: '',
      side: 'buy',
      kind: 'normal',
      shares: '',
      price: '',
      fees: '0',
      executed_on: '2026-07-24',
      notes: null,
    })
  })

  it('is not valid until the user fills it in', () => {
    expect(transactionFormSchema.safeParse(emptyTransactionForm('2026-07-24')).success).toBe(false)
  })
})
