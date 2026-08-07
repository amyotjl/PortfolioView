import { CASH_KINDS } from '@/types'
import { centsToDecimalString, toCents } from '@/lib/money'
import { formatCurrency, formatPercent } from '@/lib/format'

/**
 * Cash copy and cash labelling, as PURE functions (issue #80).
 *
 * Everything user-visible about a cash balance lives here rather than inline in a
 * component, for the same reason `sellPreflightMessage` does: the wording is the
 * part most likely to be subtly wrong, and a pure function is the only version of
 * it a unit test can pin.
 *
 * TWO RULES THE COPY OBEYS, both of which have burned this project before.
 *
 * 1. TENSE-NEUTRAL, always. The negative-balance sentence is reused verbatim as a
 *    statement of fact (the dashboard, the section header) and as a projection
 *    (typing a withdrawal that has not been saved). Anything in the past tense
 *    would be a lie in one of the two places — exactly the trap the importer's
 *    warning strings are locked down against.
 *
 * 2. EVERY FIGURE GOES THROUGH `toCents` / `centsToDecimalString`, never
 *    `parseFloat`. The projection subtracts two money strings, and that is
 *    precisely where floats lose: `0.07 - 0.29` in IEEE-754 is
 *    -0.21999999999999997. Integer cents give exactly -0.22. `lib/cash.spec.ts`
 *    probes this by asserting the intermediate cents, because the FORMATTED string
 *    happens to round the same either way — an assertion on the message text alone
 *    would not discriminate the bug.
 *
 * NEGATIVE CASH IS NOT AN ERROR. An imported broker ledger can legitimately leave
 * a portfolio negative, so these strings never claim a single cause, never say
 * "invalid", and never appear as a blocking alert. The components render them
 * through `AdvisoryNotice` with `role="status"` (polite), never `role="alert"`.
 */

/** Human labels for the six stored kinds; anything else falls through verbatim. */
const CASH_KIND_LABELS: Record<string, string> = {
  deposit: 'Deposit',
  withdrawal: 'Withdrawal',
  interest: 'Interest',
  // Named apart from `transactions.kind = 'dividend_reinvestment'` on purpose.
  dividend_cash: 'Cash dividend',
  tax: 'Tax',
  fee: 'Fee',
}

/** Kinds whose unsigned magnitude means money arriving. */
const INFLOW_KINDS = new Set(['deposit', 'interest', 'dividend_cash'])
/** Kinds whose unsigned magnitude means money leaving. */
const OUTFLOW_KINDS = new Set(['withdrawal'])

/**
 * `'dividend_cash'` -> `'Cash dividend'`; an unrecognised kind is returned AS-IS.
 *
 * The fallthrough is deliberate and is the same decision as modelling `kind` as
 * `z.string()` rather than a zod enum: a kind a newer backend introduces should
 * render as an ugly raw string, not blank a table or throw.
 */
export function cashKindLabel(kind: string): string {
  return CASH_KIND_LABELS[kind] ?? kind
}

/** True only for the six kinds this build knows about. */
export function isKnownCashKind(kind: string): boolean {
  return (CASH_KINDS as readonly string[]).includes(kind)
}

/**
 * Ledger display for one movement: the magnitude, signed by DIRECTION.
 *
 * The wire sends a movement's `amount` as an unsigned magnitude with `kind`
 * carrying the direction, so a table has to reunite them. Three cases, and none of
 * them can double-sign:
 *
 *  - the string already carries a sign (an internal kind may: a dividend reversal,
 *    a fee reimbursement) -> use it verbatim;
 *  - an unambiguous direction (`deposit`/`interest`/`dividend_cash` in,
 *    `withdrawal` out) -> apply it;
 *  - `tax` / `fee` / an unknown kind with no sign in the string -> NO invented
 *    sign. Those kinds are genuinely bidirectional under one name, so guessing
 *    would be worse than leaving the Type column to say it.
 */
export function signedCashAmount(kind: string, amount: string): string {
  const trimmed = amount.trim()
  if (trimmed.startsWith('-')) return formatCurrency(trimmed)
  if (trimmed.startsWith('+')) return `+${formatCurrency(trimmed.slice(1))}`

  const formatted = formatCurrency(trimmed)
  if (INFLOW_KINDS.has(kind)) return `+${formatted}`
  if (OUTFLOW_KINDS.has(kind)) return `-${formatted}`
  return formatted
}

/**
 * The balance a withdrawal of `amount` would leave, in exact integer cents, or
 * null when either string is unparseable.
 *
 * Exported so the float bug is DIRECTLY testable: with `{balance: '0.07', amount:
 * '0.29'}` this returns exactly `-22`, while a `parseFloat` implementation returns
 * -0.21999999999999997 dollars. Asserting on the rendered message would not catch
 * that — `formatCurrency` rounds both to `-$0.22`.
 */
export function projectedCashCents(balance: string, amount: string): number | null {
  const balanceCents = toCents(balance)
  const amountCents = toCents(amount)
  if (balanceCents === null || amountCents === null) return null
  // A withdrawal's amount is an unsigned magnitude, so it is always subtracted;
  // Math.abs guards a caller that hands over an already-signed figure.
  return balanceCents - Math.abs(amountCents)
}

/**
 * Advisory for a cash balance that is already negative, or null when the portfolio
 * does not track cash (`null`), tracks it and is flat or positive, or reports an
 * unparseable balance.
 *
 * `cashBalance === null` MEANS "DOES NOT TRACK CASH" and must not be read as zero.
 *
 * Negativity is decided from the balance STRING this copy quotes rather than from
 * `/summary`'s `cash_negative` flag, for the same reason the chart builders
 * discriminate on `payload.cash !== null`: a figure and the sentence describing it
 * cannot disagree if they come from the same value. `toCents` also makes the test
 * cent-rounded for free, so a -$0.000004 residual never raises a warning.
 *
 * THE LAST CLAUSE IS CHECKED, NOT HAND-WAVED. If deposits are understated by D,
 * recorded cash is low by D and recorded `net_deposits` is low by D — so
 * `total_return = value - deposits` is UNCHANGED while
 * `pct = return / deposits` is OVERSTATED. Hence "total value reads low and the
 * return percentage reads high". Getting that backwards would be worse than
 * saying nothing.
 */
export function negativeCashNotice(cashBalance: string | null): string | null {
  if (cashBalance === null) return null
  const cents = toCents(cashBalance)
  if (cents === null || cents >= 0) return null

  const shown = formatCurrency(centsToDecimalString(cents))
  return (
    `Cash is ${shown}. Withdrawals and trades have drawn more than this portfolio ` +
    `records receiving — usually because some deposits are not recorded yet. Until ` +
    `they are, total value reads low and the return percentage reads high.`
  )
}

/**
 * Advisory shown live in the drawer while typing a withdrawal that would take the
 * balance below zero. Null when it wouldn't, when the portfolio doesn't track cash,
 * or when either figure is not yet a parseable decimal (a half-typed amount).
 *
 * "as of the latest figures" is a DELIBERATE HEDGE. `/summary`'s balance is
 * current, not as-of the date chosen in the picker, and claiming date precision we
 * do not have is exactly the failure mode `sellPreflightMessage`'s two-branch
 * design exists to avoid. The final sentence states plainly that the entry is
 * allowed, because it is: nothing here blocks the save.
 */
export function withdrawalProjectionNotice(options: {
  cashBalance: string | null
  amount: string
}): string | null {
  const { cashBalance, amount } = options
  if (cashBalance === null || !amount.trim()) return null

  const balanceCents = toCents(cashBalance)
  const projectedCents = projectedCashCents(cashBalance, amount)
  const amountCents = toCents(amount)
  if (balanceCents === null || projectedCents === null || amountCents === null) return null
  if (projectedCents >= 0) return null

  const balanceShown = formatCurrency(centsToDecimalString(balanceCents))
  const amountShown = formatCurrency(centsToDecimalString(Math.abs(amountCents)))
  const projectedShown = formatCurrency(centsToDecimalString(projectedCents))

  return (
    `This portfolio’s cash balance is ${balanceShown} as of the latest figures. ` +
    `Withdrawing ${amountShown} takes it to ${projectedShown}. That is allowed — ` +
    `it just means some deposits are probably missing.`
  )
}

/**
 * Scope caption for the allocation section when a portfolio tracks cash.
 *
 * `/allocations`' `total_value` is HOLDINGS ONLY and is therefore less than
 * `/summary`'s `current_value` by exactly the cash balance. That divergence is
 * deliberate (a "Cash" slice would change every weight on screen, the `by_sector`
 * label set and the treemap join key), so it is stated in words instead of being
 * papered over.
 *
 * Null when the portfolio does not track cash, and also null when the balance is
 * exactly flat — at `'0.00'` the two totals genuinely agree, so there is no
 * divergence to disclose. (That is a statement about this caption only. The Cash
 * stat TILE must still render at `'0.00'`: the tile reports a tracked balance,
 * this sentence explains a discrepancy that does not exist.)
 */
export function allocationScopeNotice(options: {
  holdingsValue: string | null | undefined
  currentValue: string | null | undefined
  cashBalance: string | null | undefined
}): string | null {
  const { holdingsValue, currentValue, cashBalance } = options
  if (cashBalance === null || cashBalance === undefined) return null
  if (!holdingsValue || !currentValue) return null

  const cashCents = toCents(cashBalance)
  const holdingsCents = toCents(holdingsValue)
  const totalCents = toCents(currentValue)
  if (cashCents === null || holdingsCents === null || totalCents === null) return null
  if (cashCents === 0) return null

  const holdingsShown = formatCurrency(centsToDecimalString(holdingsCents))
  const totalShown = formatCurrency(centsToDecimalString(totalCents))
  const cashShown = formatCurrency(centsToDecimalString(cashCents))

  const scope = `Allocation covers your holdings only — ${holdingsShown} of ${totalShown} total.`
  if (totalCents === 0) {
    // A share-of-total is undefined against a zero total; say the amount only.
    return `${scope} The remaining ${cashShown} is cash.`
  }

  // Display-only RATIO of two exact integer counts (the chart/format boundary,
  // like `centsToDollars`) — not money arithmetic.
  const share = formatPercent(String(cashCents / totalCents))
  return `${scope} The remaining ${cashShown} is cash (${share}).`
}
