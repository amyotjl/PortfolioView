import { describe, expect, it } from 'vitest'
import { DECIMAL, decimalField } from './decimalField'
import { transactionFormSchema } from './transaction'
import { recurringFormSchema } from './recurring'
import { cashFormSchema } from './cash'

/**
 * The extracted decimal validator (#80).
 *
 * The point of these tests is NOT to re-test the regex — `transaction.spec.ts`
 * already covers shape, scale and sign. It is to pin the property that made the
 * extraction safe in the first place: all three forms now produce the SAME MESSAGE
 * for the same bad input, because they are the same function. Before the extraction
 * `forms/recurring.ts` carried a near-duplicate that could have drifted, and
 * `forms/cash.ts` would have been a third copy.
 */

/** First error message for a field, or undefined when it validated. */
function messageFor(schema: { safeParse: (v: unknown) => unknown }, input: unknown, field: string) {
  const result = schema.safeParse(input) as
    | { success: true }
    | { success: false; error: { issues: Array<{ path: unknown[]; message: string }> } }
  if (result.success) return undefined
  return result.error.issues.find((issue) => issue.path[0] === field)?.message
}

const transaction = (overrides: Record<string, unknown>) => ({
  symbol: 'AAPL',
  side: 'buy',
  kind: 'normal',
  shares: '10',
  price: '150.25',
  fees: '0',
  executed_on: '2026-07-24',
  notes: null,
  ...overrides,
})

const recurring = (overrides: Record<string, unknown>) => ({
  symbol: 'AAPL',
  amount_type: 'dollars',
  dollar_amount: '100.00',
  share_amount: null,
  frequency: 'monthly',
  anchor_on: '2026-07-24',
  end_on: null,
  active: true,
  ...overrides,
})

const cash = (overrides: Record<string, unknown>) => ({
  kind: 'deposit',
  amount: '100.00',
  occurred_on: '2026-07-24',
  notes: null,
  ...overrides,
})

describe('decimalField', () => {
  it('validates without arithmetic and returns the value byte-identical', () => {
    const field = decimalField({ label: 'Amount', scale: 2, allowZero: false })
    // `'5.10'` must survive as typed — a schema that coerced to number emits `5.1`.
    expect(field.parse('5.10')).toBe('5.10')
    expect(field.parse('  5.10  ')).toBe('5.10')
  })

  it('rejects a sign, which is why the cash API sends unsigned magnitudes', () => {
    expect(DECIMAL.test('-5.00')).toBe(false)
    expect(DECIMAL.test('+5.00')).toBe(false)
    const field = decimalField({ label: 'Amount', scale: 2, allowZero: false })
    expect(field.safeParse('-5.00').success).toBe(false)
  })

  it('orders its checks shape -> scale -> sign, so a bad shape reports "must be a number"', () => {
    const field = decimalField({ label: 'Amount', scale: 2, allowZero: false })
    const result = field.safeParse('abc')
    expect(result.success).toBe(false)
    if (!result.success) {
      expect(result.error.issues.map((i) => i.message)).toContain('Amount must be a number')
    }
  })

  it('pluralizes the scale message, and only for scale 1', () => {
    expect(
      decimalField({ label: 'X', scale: 1, allowZero: true }).safeParse('1.23').success,
    ).toBe(false)
    const one = decimalField({ label: 'X', scale: 1, allowZero: true }).safeParse('1.23')
    if (!one.success) expect(one.error.issues[0].message).toBe('X allows at most 1 decimal place')
    const two = decimalField({ label: 'X', scale: 2, allowZero: true }).safeParse('1.234')
    if (!two.success) expect(two.error.issues[0].message).toBe('X allows at most 2 decimal places')
  })
})

describe('all three forms share one validator', () => {
  it('gives the same "must be a number" message for the same bad input', () => {
    const expected = (label: string) => `${label} must be a number`
    expect(messageFor(transactionFormSchema, transaction({ fees: 'abc' }), 'fees')).toBe(
      expected('Fees'),
    )
    expect(
      messageFor(recurringFormSchema, recurring({ dollar_amount: 'abc' }), 'dollar_amount'),
    ).toBe(expected('Amount'))
    expect(messageFor(cashFormSchema, cash({ amount: 'abc' }), 'amount')).toBe(expected('Amount'))
  })

  it('gives the same 2dp scale message on every 2dp money field', () => {
    expect(messageFor(transactionFormSchema, transaction({ fees: '1.999' }), 'fees')).toBe(
      'Fees allows at most 2 decimal places',
    )
    expect(
      messageFor(recurringFormSchema, recurring({ dollar_amount: '1.999' }), 'dollar_amount'),
    ).toBe('Amount allows at most 2 decimal places')
    expect(messageFor(cashFormSchema, cash({ amount: '1.999' }), 'amount')).toBe(
      'Amount allows at most 2 decimal places',
    )
  })

  it('gives the same "greater than zero" message where zero is disallowed', () => {
    expect(messageFor(transactionFormSchema, transaction({ shares: '0' }), 'shares')).toBe(
      'Shares must be greater than zero',
    )
    expect(
      messageFor(recurringFormSchema, recurring({ dollar_amount: '0.00' }), 'dollar_amount'),
    ).toBe('Amount must be greater than zero')
    expect(messageFor(cashFormSchema, cash({ amount: '0.00' }), 'amount')).toBe(
      'Amount must be greater than zero',
    )
  })

  it('gives the same "is required" message on a blank field', () => {
    expect(messageFor(transactionFormSchema, transaction({ shares: '' }), 'shares')).toBe(
      'Shares is required',
    )
    expect(messageFor(cashFormSchema, cash({ amount: '' }), 'amount')).toBe('Amount is required')
  })
})
