import { describe, expect, it } from 'vitest'
import {
  emptyRecurringForm,
  recurringFormSchema,
  toRecurringInput,
  type RecurringFormValues,
} from './recurring'

function valid(overrides: Record<string, unknown> = {}) {
  return {
    symbol: 'VTI',
    amount_type: 'dollars',
    dollar_amount: '500.00',
    share_amount: null,
    frequency: 'monthly',
    anchor_on: '2026-08-01',
    end_on: null,
    active: true,
    ...overrides,
  }
}

function errorFor(input: unknown, field: string): string | undefined {
  const result = recurringFormSchema.safeParse(input)
  if (result.success) return undefined
  return result.error.issues.find((issue) => issue.path[0] === field)?.message
}

describe('recurringFormSchema', () => {
  it('accepts a well-formed dollars rule', () => {
    expect(recurringFormSchema.safeParse(valid()).success).toBe(true)
  })

  it('accepts a well-formed shares rule', () => {
    const input = valid({ amount_type: 'shares', dollar_amount: null, share_amount: '1.5' })
    expect(recurringFormSchema.safeParse(input).success).toBe(true)
  })

  it('uppercases the symbol', () => {
    expect(recurringFormSchema.parse(valid({ symbol: 'vti' })).symbol).toBe('VTI')
  })

  describe('requires only the active mode’s amount', () => {
    it('requires dollar_amount in dollars mode', () => {
      expect(errorFor(valid({ dollar_amount: null }), 'dollar_amount')).toBeDefined()
      expect(errorFor(valid({ dollar_amount: '' }), 'dollar_amount')).toBeDefined()
    })

    it('requires share_amount in shares mode', () => {
      const input = valid({ amount_type: 'shares', dollar_amount: null, share_amount: null })
      expect(errorFor(input, 'share_amount')).toBeDefined()
    })

    it('ignores the inactive mode’s field entirely', () => {
      // Switching modes must not leave a blocking error on the hidden field.
      const dollarsWithJunkShares = valid({ share_amount: 'not-a-number' })
      expect(recurringFormSchema.safeParse(dollarsWithJunkShares).success).toBe(true)

      const sharesWithJunkDollars = valid({
        amount_type: 'shares',
        share_amount: '2',
        dollar_amount: 'not-a-number',
      })
      expect(recurringFormSchema.safeParse(sharesWithJunkDollars).success).toBe(true)
    })
  })

  describe('amount scale and sign', () => {
    it('holds dollars to 2dp and shares to 8dp', () => {
      expect(errorFor(valid({ dollar_amount: '1.999' }), 'dollar_amount')).toContain(
        '2 decimal places',
      )
      const shares = (value: string) =>
        valid({ amount_type: 'shares', dollar_amount: null, share_amount: value })
      expect(recurringFormSchema.safeParse(shares('1.12345678')).success).toBe(true)
      expect(errorFor(shares('1.123456789'), 'share_amount')).toContain('8 decimal places')
    })

    it('rejects zero and non-numeric amounts', () => {
      expect(errorFor(valid({ dollar_amount: '0' }), 'dollar_amount')).toContain(
        'greater than zero',
      )
      expect(errorFor(valid({ dollar_amount: '0.00' }), 'dollar_amount')).toContain(
        'greater than zero',
      )
      for (const bad of ['abc', '-5', '1e3', '1,000']) {
        expect(errorFor(valid({ dollar_amount: bad }), 'dollar_amount'), bad).toBeDefined()
      }
    })

    it('preserves the amount string exactly', () => {
      expect(recurringFormSchema.parse(valid({ dollar_amount: '500.00' })).dollar_amount).toBe(
        '500.00',
      )
    })
  })

  describe('frequency and dates', () => {
    it('accepts every documented frequency', () => {
      for (const frequency of ['weekly', 'biweekly', 'monthly', 'quarterly']) {
        expect(recurringFormSchema.safeParse(valid({ frequency })).success, frequency).toBe(true)
      }
    })

    it('rejects a frequency the backend does not know', () => {
      expect(recurringFormSchema.safeParse(valid({ frequency: 'daily' })).success).toBe(false)
      expect(recurringFormSchema.safeParse(valid({ frequency: 'annually' })).success).toBe(false)
    })

    it('requires an ISO anchor date', () => {
      for (const bad of ['2026-8-1', '08/01/2026', '']) {
        expect(errorFor(valid({ anchor_on: bad }), 'anchor_on'), bad).toBeDefined()
      }
    })

    it('treats an empty end date as "no end date"', () => {
      expect(recurringFormSchema.parse(valid({ end_on: '' })).end_on).toBeNull()
      expect(recurringFormSchema.parse(valid({ end_on: null })).end_on).toBeNull()
    })

    it('rejects an end date on or before the start (it would never run)', () => {
      expect(errorFor(valid({ end_on: '2026-08-01' }), 'end_on')).toContain('after the start')
      expect(errorFor(valid({ end_on: '2026-07-01' }), 'end_on')).toContain('after the start')
      expect(recurringFormSchema.safeParse(valid({ end_on: '2026-08-02' })).success).toBe(true)
    })

    it('accepts a past anchor — the server clamps next_run_on forward', () => {
      // Deliberately not a client error: the model clamps to the first slot on or
      // after today so nothing materializes historically.
      expect(recurringFormSchema.safeParse(valid({ anchor_on: '2020-01-01' })).success).toBe(true)
    })
  })

  it('exposes no side field, since v1 is buy-only', () => {
    const parsed = recurringFormSchema.parse(valid())
    expect('side' in parsed).toBe(false)
  })
})

describe('toRecurringInput', () => {
  const parse = (overrides: Record<string, unknown> = {}): RecurringFormValues =>
    recurringFormSchema.parse(valid(overrides))

  it('always sends side "buy"', () => {
    expect(toRecurringInput(parse()).side).toBe('buy')
  })

  it('nulls share_amount in dollars mode', () => {
    const input = toRecurringInput(parse({ share_amount: '99' }))
    expect(input.dollar_amount).toBe('500.00')
    expect(input.share_amount).toBeNull()
  })

  it('nulls dollar_amount in shares mode', () => {
    const input = toRecurringInput(
      parse({ amount_type: 'shares', share_amount: '1.5', dollar_amount: '999' }),
    )
    expect(input.share_amount).toBe('1.5')
    expect(input.dollar_amount).toBeNull()
  })

  it('passes the schedule fields through unchanged', () => {
    const input = toRecurringInput(parse({ frequency: 'quarterly', end_on: '2027-01-01' }))
    expect(input.frequency).toBe('quarterly')
    expect(input.anchor_on).toBe('2026-08-01')
    expect(input.end_on).toBe('2027-01-01')
    expect(input.active).toBe(true)
  })
})

describe('emptyRecurringForm', () => {
  it('defaults to an active monthly dollars rule anchored on the given date', () => {
    expect(emptyRecurringForm('2026-07-25')).toEqual({
      symbol: '',
      amount_type: 'dollars',
      dollar_amount: '',
      share_amount: null,
      frequency: 'monthly',
      anchor_on: '2026-07-25',
      end_on: null,
      active: true,
    })
  })

  it('is not valid until a ticker and amount are filled in', () => {
    expect(recurringFormSchema.safeParse(emptyRecurringForm('2026-07-25')).success).toBe(false)
  })
})
