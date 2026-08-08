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
 * A KIND THIS FORM CANNOT REPRESENT IS PRESERVED, NEVER SUBSTITUTED — and that is
 * the bug this module shipped with (B5). An imported `fee` row opened in the edit
 * drawer and saved WITHOUT THE USER TOUCHING ANYTHING came back as a `withdrawal`:
 * the seed mapped the unoffered kind onto the offered kind matching its sign (which
 * protected the sign, and did), the SelectButton rendered only those two with no
 * memory of the original, and the submit sent the substitute. `withdrawal` is
 * EXTERNAL, so a no-op save silently converted broker-internal money into a user
 * contribution: `net_deposits` moved and the benchmark's shadow ETF started matching
 * a sell that never happened. Measured on all four internal kinds, not just `fee`
 * (`tax`/`interest`/`dividend_cash` all became `deposit`).
 *
 * The fix is `locked_kind`, below: the row's own kind rides along in form state and
 * is submitted verbatim. Widening the SelectButton to six kinds was REJECTED for the
 * reason in the paragraph above — offering `dividend_cash` as something to hand-enter
 * invites exactly the miscategorization the external/internal split exists to
 * prevent. A control that cannot represent the current value is not rendered at all.
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
  /**
   * The SelectButton's value, and the only kind a user can choose. For a row whose
   * real kind this drawer cannot offer it is also the SIGN CARRIER and nothing else
   * — see `locked_kind`.
   */
  kind: z.enum(['deposit', 'withdrawal']),
  /**
   * The row's OWN kind when the drawer cannot represent it (`interest`,
   * `dividend_cash`, `tax`, `fee`, or anything a newer backend adds), else `null`.
   *
   * No control writes this: the only producer of a non-null value is `toCashForm`,
   * whose argument is a persisted `CashTransaction`. That is what makes "the create
   * path cannot produce an internal kind" structural rather than incidental — a
   * create has no row to take one from, and `emptyCashForm`'s return type says
   * `null` literally.
   *
   * Required, not `.optional()` / `.default(null)`: a new call site must DECIDE.
   * Forgetting a defaulted field is precisely how B5 comes back.
   */
  locked_kind: z.string().nullable(),
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

/**
 * Fields the drawer renders — the allow-list `mapApiError` maps 422 details onto.
 *
 * `locked_kind` is absent on purpose: it is not a wire field and has no control, and
 * the server's error key for a bad kind is `kind`. The drawer binds `errors.kind` to
 * the read-only Type display as well as to the SelectButton, so that 422 is still
 * visible on a row whose SelectButton is not rendered.
 */
export const CASH_FORM_FIELDS = ['kind', 'amount', 'occurred_on', 'notes'] as const

/**
 * A fresh deposit, dated today, amount blank.
 *
 * The `locked_kind: null` in the RETURN TYPE is load-bearing, not decoration: it is
 * the compile-time half of "a create can never submit an internal kind". The runtime
 * half is that nothing but `toCashForm(row)` can produce a non-null one.
 */
export function emptyCashForm(occurredOn: string): CashFormValues & { locked_kind: null } {
  return {
    kind: 'deposit',
    locked_kind: null,
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
 *
 * EXPORTED so the coverage can be asserted at RUNTIME too. The guard above is
 * compile-time only, which a re-gate probe demonstrated: swapping the map for an
 * inlined ternary passes every test and `vue-tsc`, because for today's two kinds the
 * ternary is behaviourally identical. `cash.spec.ts` therefore pins that every
 * `CASH_KIND_OPTIONS` value has an entry here and vice versa, so a JS-only consumer
 * cannot slip past the type system.
 */
export const CASH_KIND_SIGN: Record<CashFormValues['kind'], 1 | -1> = {
  deposit: 1,
  withdrawal: -1,
}

/**
 * True for the two kinds this drawer offers, decided BY THE SCHEMA ITSELF rather
 * than by a second list that could drift from it. Anything else — the four internal
 * kinds, or a kind a newer backend introduces — is preserved through `locked_kind`.
 */
export function isOfferedCashKind(kind: string): kind is CashFormValues['kind'] {
  return cashFormSchema.shape.kind.safeParse(kind).success
}

/**
 * Form values -> request body: the unsigned magnitude gets its sign back, and a kind
 * the drawer could not offer goes out exactly as it came in.
 *
 * Exact integer cents throughout, never `parseFloat` — `'0.29'` must not become
 * `-0.28999999999999998`. `centsToDecimalString` re-emits 2dp, which is lossless
 * for a `numeric(12,2)` column and is what the controller's own tests post.
 *
 * ONE ARGUMENT, deliberately: resolving the kind against a second `CashTransaction`
 * parameter would work, and every call site that forgot to pass it would silently be
 * B5 again. The row's kind travels inside the values instead, so there is nothing to
 * forget.
 */
export function toCashInput(values: CashFormValues): CashInput {
  return {
    // PRESERVED, not substituted. `locked_kind` is null for the offered kinds, so a
    // deliberate deposit<->withdrawal change by the user still goes through.
    kind: values.locked_kind ?? values.kind,
    /**
     * The sign still comes from `values.kind`, which for a locked row is the offered
     * kind MATCHING THE ROW'S OWN SIGN (see `toCashForm`) and is never rendered. So
     * the broker's direction round-trips verbatim in both directions — a negative
     * `fee` stays negative, a positive `tax` refund stays positive — while the
     * magnitude, date and notes stay editable.
     */
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
 * does not offer. Two things happen for it, and BOTH are needed:
 *
 *  - `locked_kind` remembers the real kind, so the save preserves it (B5). Without
 *    this, an untouched save reclassified broker-internal money as a user
 *    contribution and moved `net_deposits`.
 *  - `kind` still falls back to the offered kind MATCHING THE SIGN, not
 *    unconditionally to `deposit`, because it is what `signOnTheWire` reads: a
 *    −$12.50 fee treated as a deposit would flip the direction of real money.
 *
 * The `formKindFor` fallback is therefore no longer user-visible at all — the drawer
 * does not render the SelectButton for a locked row — but it is still what keeps the
 * sign, so it is still correct and still tested.
 */
export function toCashForm(cashTransaction: CashTransaction): CashFormValues {
  return {
    kind: formKindFor(cashTransaction.kind, cashTransaction.amount),
    locked_kind: isOfferedCashKind(cashTransaction.kind) ? null : cashTransaction.kind,
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

/**
 * The offered kind that carries `amount`'s sign. For an offered kind that IS the
 * kind; for a locked one it is a sign proxy that never reaches the wire as a kind.
 */
function formKindFor(kind: string, amount: string): CashFormValues['kind'] {
  if (isOfferedCashKind(kind)) return kind
  const cents = toCents(amount)
  return cents !== null && cents < 0 ? 'withdrawal' : 'deposit'
}
