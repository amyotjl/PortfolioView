import { describe, expect, it } from 'vitest'
import {
  cashFormSchema,
  emptyCashForm,
  toCashForm,
  toCashInput,
  type CashFormValues,
} from './cash'
import { toCents } from '@/lib/money'
import type { CashTransaction } from '@/types'

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

    it('rejects a SIGNED amount: the FORM is unsigned, the WIRE is signed', () => {
      // Which is exactly why the conversion below has to exist in both directions:
      // the wire amount IS signed, so an edit form seeded with it verbatim hits this
      // rejection and no withdrawal can be edited at all.
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

/**
 * THE SIGN BOUNDARY, in both directions — the gap that made a withdrawal
 * unrecordable from the UI (a 422 on `amount`) while 1,434 tests stayed green,
 * because every backend test posted an already-signed body and e2e only ever posted
 * a deposit. Neither of those exercises `toCashInput`, which is the function the
 * drawer actually calls.
 */
describe('toCashInput', () => {
  it('applies the sign the wire requires, for BOTH kinds', () => {
    expect(toCashInput(cashFormSchema.parse(valid({ kind: 'deposit', amount: '1500.00' })))).toEqual(
      {
        kind: 'deposit',
        amount: '1500.00',
        occurred_on: '2026-08-03',
        notes: null,
      },
    )
    expect(
      toCashInput(cashFormSchema.parse(valid({ kind: 'withdrawal', amount: '1500.00' }))),
    ).toEqual({
      kind: 'withdrawal',
      // NEGATIVE. `{"kind":"withdrawal","amount":"1500.00"}` is a 422 on `amount`:
      // the model requires a withdrawal to be negative and refuses to guess.
      amount: '-1500.00',
      occurred_on: '2026-08-03',
      notes: null,
    })
  })

  it('keeps every cent exactly, in integer cents rather than a float', () => {
    // 0.29 has no exact binary representation; a parseFloat/negate implementation
    // emits -0.28999999999999998 for one of these and numeric(12,2) would round the
    // cent away silently.
    expect(toCashInput(cashFormSchema.parse(valid({ kind: 'withdrawal', amount: '0.29' }))).amount).toBe(
      '-0.29',
    )
    expect(toCashInput(cashFormSchema.parse(valid({ amount: '5.10' }))).amount).toBe('5.10')
    // A magnitude typed without cents still reaches the API as a decimal.
    expect(toCashInput(cashFormSchema.parse(valid({ amount: '1000' }))).amount).toBe('1000.00')
  })

  it('carries kind, date and notes through unchanged', () => {
    expect(
      toCashInput(
        cashFormSchema.parse(
          valid({ kind: 'withdrawal', occurred_on: '2026-08-01', notes: '  rent  ' }),
        ),
      ),
    ).toMatchObject({ kind: 'withdrawal', occurred_on: '2026-08-01', notes: 'rent' })
  })
})

describe('toCashForm', () => {
  /** A server row, signed exactly as `/cash_transactions` emits one. */
  function row(overrides: Partial<CashTransaction> = {}): CashTransaction {
    return {
      id: 7,
      portfolio_id: 3,
      kind: 'withdrawal',
      // Unpadded on purpose: money strings are BigDecimal#to_s("F") and drop
      // trailing zeros, so this is the real shape, not '-1500.00'.
      amount: '-1500.0',
      occurred_on: '2026-08-03',
      notes: null,
      created_at: '2026-08-03T12:00:00Z',
      updated_at: '2026-08-03T12:00:00Z',
      ...overrides,
    }
  }

  it('seeds the form with the MAGNITUDE, so the edit drawer validates', () => {
    const seeded = toCashForm(row())
    expect(seeded.kind).toBe('withdrawal')
    expect(seeded.amount).toBe('1500.00')
    // The point of the whole function: the signed figure the server sent would be
    // rejected by the form's own schema.
    expect(cashFormSchema.safeParse(seeded).success).toBe(true)
    expect(cashFormSchema.safeParse({ ...seeded, amount: row().amount }).success).toBe(false)
  })

  it('leaves a deposit positive and passes date and notes through', () => {
    expect(toCashForm(row({ kind: 'deposit', amount: '10000.0', notes: 'paycheque' }))).toEqual({
      kind: 'deposit',
      amount: '10000.00',
      occurred_on: '2026-08-03',
      notes: 'paycheque',
    })
  })

  it('maps an imported internal kind to the offered kind that MATCHES THE SIGN', () => {
    // The drawer offers deposit/withdrawal only, so an imported `fee`/`tax`/
    // `dividend_cash` row has to be shown as one of them. Choosing by sign keeps the
    // direction of real money: seeding a -$12.50 fee as a `deposit` would flip it to
    // +$12.50 the moment the user pressed Save.
    expect(toCashForm(row({ kind: 'fee', amount: '-12.5' })).kind).toBe('withdrawal')
    expect(toCashForm(row({ kind: 'tax', amount: '40.0' })).kind).toBe('deposit')
    expect(toCashForm(row({ kind: 'dividend_cash', amount: '3.75' })).kind).toBe('deposit')
    expect(toCashForm(row({ kind: 'rebate', amount: '-1.0' })).kind).toBe('withdrawal')
  })

  it('round-trips signed -> form -> signed as the IDENTITY, withdrawal included', () => {
    // The composed edit path: GET a row, seed the drawer, press Save. If either half
    // of the conversion is missing or double-applied, the amount that goes back is
    // not the amount that came out.
    for (const [kind, amount, expected] of [
      ['withdrawal', '-1500.0', '-1500.00'],
      ['withdrawal', '-0.29', '-0.29'],
      ['deposit', '10000.0', '10000.00'],
      ['deposit', '5.1', '5.10'],
    ] as const) {
      const seeded = cashFormSchema.parse(toCashForm(row({ kind, amount })))
      const resubmitted = toCashInput(seeded)
      expect(resubmitted.kind, amount).toBe(kind)
      expect(resubmitted.amount, amount).toBe(expected)
      // Identity in VALUE, not in text: '-1500.0' and '-1500.00' are the same money,
      // and cents are the contract's smallest unit.
      expect(toCents(resubmitted.amount), amount).toBe(toCents(amount))
    }
  })
})
