import { describe, expect, it } from 'vitest'
import { cashFormSchema, emptyCashForm, toCashInput, type CashFormValues } from './cash'

function valid(overrides: Partial<Record<keyof CashFormValues, unknown>> = {}) {
  return {
    kind: 'deposit',
    amount: '5000.00',
    occurred_on: '2026-08-03',
    notes: null,
    ...overrides,
  }
}

/** First error message for a field, or undefined when the field validated. */
function errorFor(input: unknown, field: keyof CashFormValues): string | undefined {
  const result = cashFormSchema.safeParse(input)
  if (result.success) return undefined
  return result.error.issues.find((issue) => issue.path[0] === field)?.message
}

describe('cashFormSchema', () => {
  it('accepts a well-formed deposit and a well-formed withdrawal', () => {
    expect(cashFormSchema.safeParse(valid()).success).toBe(true)
    expect(cashFormSchema.safeParse(valid({ kind: 'withdrawal' })).success).toBe(true)
  })

  it('offers only the two external kinds — the importer writes the other four', () => {
    // Manual entry must not let a user hand-classify a movement as internal: that
    // would silently change net_deposits and the benchmark denominator.
    for (const internal of ['interest', 'dividend_cash', 'tax', 'fee']) {
      expect(cashFormSchema.safeParse(valid({ kind: internal })).success, internal).toBe(false)
    }
    expect(cashFormSchema.safeParse(valid({ kind: 'transfer' })).success).toBe(false)
  })

  describe('amount keeps its string precision', () => {
    it("does NOT reformat: '5.10' survives byte-identical", () => {
      // The whole reason the amount is a text input and not a numeric one. A schema
      // that coerced to number would emit `5.1` and the cent would be gone from the
      // request body.
      expect(cashFormSchema.parse(valid({ amount: '5.10' })).amount).toBe('5.10')
      expect(cashFormSchema.parse(valid({ amount: '0.10' })).amount).toBe('0.10')
      expect(cashFormSchema.parse(valid({ amount: '1000.00' })).amount).toBe('1000.00')
    })

    it('trims surrounding whitespace but nothing else', () => {
      expect(cashFormSchema.parse(valid({ amount: '  5.10 ' })).amount).toBe('5.10')
    })

    it('allows 2dp (numeric(12,2)) and rejects 3', () => {
      expect(cashFormSchema.safeParse(valid({ amount: '5.99' })).success).toBe(true)
      expect(errorFor(valid({ amount: '5.999' }), 'amount')).toContain('2 decimal places')
    })

    it('rejects zero — a zero movement is what the amount-sign CHECK forbids', () => {
      expect(errorFor(valid({ amount: '0' }), 'amount')).toContain('greater than zero')
      expect(errorFor(valid({ amount: '0.00' }), 'amount')).toContain('greater than zero')
    })

    it('rejects a SIGNED amount: direction is carried by kind, not by the number', () => {
      // Also the reason the API emits a movement's amount unsigned — an edit form
      // repopulating from a signed GET would hit exactly this rejection.
      expect(errorFor(valid({ amount: '-500.00' }), 'amount')).toBeDefined()
      expect(errorFor(valid({ amount: '+500.00' }), 'amount')).toBeDefined()
    })

    it('rejects non-numeric and exponent forms', () => {
      for (const bad of ['abc', '1e3', '1,000', '1.2.3', '']) {
        expect(errorFor(valid({ amount: bad }), 'amount'), bad).toBeDefined()
      }
    })
  })

  describe('date and notes', () => {
    it('requires an ISO YYYY-MM-DD date', () => {
      for (const bad of ['2026-8-3', '08/03/2026', '20260803', '']) {
        expect(errorFor(valid({ occurred_on: bad }), 'occurred_on'), bad).toBeDefined()
      }
    })

    it('accepts a weekend date — the server buckets it to the next trading day', () => {
      // 2026-08-01 is a Saturday. Deliberately NOT a validation error; the drawer
      // shows the "next trading day" advisory instead.
      expect(cashFormSchema.safeParse(valid({ occurred_on: '2026-08-01' })).success).toBe(true)
    })

    it('trims an empty notes field to null rather than sending an empty string', () => {
      expect(cashFormSchema.parse(valid({ notes: '   ' })).notes).toBeNull()
      expect(cashFormSchema.parse(valid({ notes: '' })).notes).toBeNull()
      expect(cashFormSchema.parse(valid({ notes: '  paycheque  ' })).notes).toBe('paycheque')
    })
  })

  it('does not model the balance at all — negative cash is legal', () => {
    // There is no "this would overdraw" rule anywhere in the schema, by design: an
    // imported broker ledger can legitimately leave a portfolio negative, so the
    // drawer advises and the server accepts.
    expect(cashFormSchema.safeParse(valid({ kind: 'withdrawal', amount: '999999.99' })).success).toBe(
      true,
    )
  })
})

describe('emptyCashForm', () => {
  it('defaults to a deposit on the given date with a blank amount', () => {
    expect(emptyCashForm('2026-08-03')).toEqual({
      kind: 'deposit',
      amount: '',
      occurred_on: '2026-08-03',
      notes: null,
    })
  })

  it('is not valid until the user fills it in', () => {
    expect(cashFormSchema.safeParse(emptyCashForm('2026-08-03')).success).toBe(false)
  })
})

describe('toCashInput', () => {
  it('passes the amount through untouched', () => {
    expect(toCashInput(cashFormSchema.parse(valid({ amount: '5.10' })))).toEqual({
      kind: 'deposit',
      amount: '5.10',
      occurred_on: '2026-08-03',
      notes: null,
    })
  })
})
