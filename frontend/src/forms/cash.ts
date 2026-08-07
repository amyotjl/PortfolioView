import { z } from 'zod'
import { decimalField } from './decimalField'
import type { CashInput } from '@/composables/useCashTransactions'

/**
 * Client-side schema for the cash drawer (create + edit) — issue #80.
 *
 * TWO KINDS, NOT SIX. The schema stores six kinds and the importer writes all six,
 * but manual entry offers only `deposit` and `withdrawal`: those are the two a
 * person actually performs. `interest`, `dividend_cash`, `tax` and `fee` are
 * things the broker did inside the account, and they arrive through the ledger
 * importer. Offering them here would invite a user to hand-classify a movement in
 * a way that silently changes `net_deposits` and the benchmark denominator.
 *
 * `amount` IS AN UNSIGNED MAGNITUDE — `kind` carries the direction, matching the
 * wire contract. That is also why the shared `decimalField` (whose regex rejects
 * a sign) can be reused unchanged for the edit path: a GET never hands this form
 * a `-500`.
 *
 * NOT A MODE OF `transactionFormSchema`, and not a discriminated union with it:
 * six of the transaction drawer's eight fields would have to be conditioned away,
 * three of its reactive side effects are keyed on `symbol` (price lookup, holdings
 * pre-flight, estimated total) and each guard would be a future place an
 * `/instruments/:id/price` call leaks for a deposit.
 */

/** The two kinds the drawer offers, with the labels its SelectButton renders. */
export const CASH_KIND_OPTIONS = [
  { label: 'Deposit', value: 'deposit' },
  { label: 'Withdrawal', value: 'withdrawal' },
] as const

export const cashFormSchema = z.object({
  kind: z.enum(['deposit', 'withdrawal']),
  // numeric(12,2): cents are the smallest unit a bank statement has.
  amount: decimalField({ label: 'Amount', scale: 2, allowZero: false }),
  occurred_on: z.string().regex(/^\d{4}-\d{2}-\d{2}$/, 'Pick a date'),
  // Empty textarea -> null, so we send an explicit "no notes" rather than "".
  notes: z
    .string()
    .max(2000, 'Keep notes under 2000 characters')
    .nullable()
    .transform((value) => (value && value.trim().length > 0 ? value.trim() : null)),
})

export type CashFormValues = z.infer<typeof cashFormSchema>

/** Fields the drawer renders — the allow-list `mapApiError` maps 422 details onto. */
export const CASH_FORM_FIELDS = ['kind', 'amount', 'occurred_on', 'notes'] as const

/** A fresh deposit, dated today, amount blank. */
export function emptyCashForm(occurredOn: string): CashFormValues {
  return {
    kind: 'deposit',
    amount: '',
    occurred_on: occurredOn,
    notes: null,
  }
}

/**
 * Form values -> request body. A pass-through by design: there is no derivation
 * to do, and the amount string must reach the API exactly as typed.
 */
export function toCashInput(values: CashFormValues): CashInput {
  return {
    kind: values.kind,
    amount: values.amount,
    occurred_on: values.occurred_on,
    notes: values.notes,
  }
}
