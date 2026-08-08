import { z } from 'zod'
import { decimalField } from './decimalField'
import { cashMagnitude } from '@/lib/cash'
import { centsToDecimalString, toCents } from '@/lib/money'
import type { CashInput } from '@/composables/useCashTransactions'
import type { CashTransaction } from '@/types'

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
 * `amount` IS AN UNSIGNED MAGNITUDE IN THE FORM AND SIGNED ON THE WIRE, and this
 * module is the boundary that converts, in BOTH directions. The wire contract is
 * settled (docs/API_SHAPES.md): every money figure is signed, `deposit` positive
 * and `withdrawal` negative, enforced by a DB CHECK and a model validation — so an
 * unsigned body is a 422 on `amount`, not a coerced value. The form stays unsigned
 * because the shared `decimalField` regex rejects a sign and because "how much
 * moved" plus a Deposit/Withdrawal toggle is what a person types.
 *
 * Both directions have to exist, and the missing one is a real bug either way:
 * `toCashInput` applies the sign on the way out, `toCashForm` strips it on the way
 * in (a signed `-500` from a GET fails `decimalField` outright). Neither is derived
 * at a call site — a future kind must not be able to pick up a sign by accident.
 *
 * THE SIGN IS NOT DERIVED SERVER-SIDE FROM `kind`, deliberately: `tax` and `fee`
 * are genuinely ± under one kind name (a refund, a reimbursement), so a
 * kind-derived sign cannot express them. It is only derivable here because this
 * form offers exactly the two kinds whose direction is unambiguous.
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
 * The sign each offered kind carries ON THE WIRE, as a single mapping rather than a
 * ternary at the conversion site. It is keyed by the SCHEMA's kind union, so widening
 * `cashFormSchema`'s enum without adding an entry here is a type error — a new kind
 * cannot silently inherit `+` from a `kind === 'withdrawal' ? -1 : 1` written inline.
 * (Widening only `CASH_KIND_OPTIONS`, which is the render list, would fail the
 * schema's own validation instead.)
 *
 * Only the two unambiguous kinds appear, which is the whole reason this derivation
 * is legitimate here and illegitimate on the server (see the module note).
 */
const CASH_KIND_SIGN: Record<CashFormValues['kind'], 1 | -1> = {
  deposit: 1,
  withdrawal: -1,
}

/**
 * Form values -> request body: the unsigned magnitude gets `kind`'s sign.
 *
 * Exact integer cents throughout, never `parseFloat` — `'0.29'` must not become
 * `-0.28999999999999998`. `centsToDecimalString` re-emits 2dp, which is lossless
 * for a `numeric(12,2)` column and is what the controller's own tests post.
 */
export function toCashInput(values: CashFormValues): CashInput {
  return {
    kind: values.kind,
    amount: signOnTheWire(values.kind, values.amount),
    occurred_on: values.occurred_on,
    notes: values.notes,
  }
}

/**
 * An existing movement -> form values: the signed wire amount becomes an unsigned
 * magnitude, because `decimalField`'s regex rejects a sign and would otherwise
 * make every withdrawal un-editable ("Amount must be a number" on a figure the
 * server itself sent).
 *
 * A row written by the IMPORTER may carry one of the four internal kinds this form
 * does not offer. Those fall back to the offered kind that MATCHES THE SIGN, not
 * unconditionally to `deposit`: a −$12.50 fee seeded as a deposit would silently
 * flip the direction of real money on save. The server stays authoritative about
 * what an edit may change.
 */
export function toCashForm(cashTransaction: CashTransaction): CashFormValues {
  return {
    kind: formKindFor(cashTransaction.kind, cashTransaction.amount),
    amount: cashMagnitude(cashTransaction.amount),
    occurred_on: cashTransaction.occurred_on,
    notes: cashTransaction.notes,
  }
}

function signOnTheWire(kind: CashFormValues['kind'], magnitude: string): string {
  const cents = toCents(magnitude)
  if (cents === null) {
    // Unreachable through the drawer (the schema validates first), but a caller
    // must never LOSE the sign: prefix it textually rather than emit a positive
    // figure that reads as a deposit.
    const bare = magnitude.trim().replace(/^[+-]/, '')
    return CASH_KIND_SIGN[kind] === -1 ? `-${bare}` : bare
  }
  return centsToDecimalString(CASH_KIND_SIGN[kind] * Math.abs(cents))
}

function formKindFor(kind: string, amount: string): CashFormValues['kind'] {
  if (kind === 'deposit' || kind === 'withdrawal') return kind
  const cents = toCents(amount)
  return cents !== null && cents < 0 ? 'withdrawal' : 'deposit'
}
