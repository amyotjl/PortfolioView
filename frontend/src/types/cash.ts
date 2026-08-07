import { z } from 'zod'
import { DecimalString, IsoDate, IsoDateTime } from './common'
import { paginationMetaSchema } from './transactions'

/**
 * Liquid cash (issue #80).
 *
 * A portfolio "tracks cash" iff it has at least one `cash_transactions` row.
 * That single predicate governs the whole reporting basis, and the wire contract
 * exposes it three equivalent ways which are pinned to agree by contract test:
 *
 *   summary.deposit_basis === 'cash'  <=>  candles.cash !== null
 *                                    <=>  summary.cash_balance !== null
 *
 * THE ONE RULE THAT MATTERS MOST HERE: `cash_balance` is `string | null` and
 * `null` is NOT zero. `null` means "this portfolio does not track cash";
 * `'0.00'` means "it tracks cash and is exactly flat". Both states are reachable
 * and they mean different things, so nothing in this chain may `?? 0`, `|| 0` or
 * `.default(...)` the value — an existing trades-only portfolio would silently
 * start claiming a $0.00 cash balance it never recorded.
 *
 * SIGN RULE, stated once and applied everywhere in the contract:
 * a single MOVEMENT is an unsigned magnitude plus a direction carried by `kind`;
 * an AGGREGATE is signed. So `cash_transaction.amount` is a magnitude while
 * `summary.cash_balance`, `candles.cash[].v` and `candles.flows[].amount` are
 * signed. (Emitting movements signed was considered and rejected: an edit form
 * repopulating from GET would hand `-500` to the shared DECIMAL regex in
 * `forms/decimalField.ts`, which deliberately rejects a sign.)
 */

/**
 * Every kind the backend stores. The IMPORTER writes all six; the manual entry
 * form offers only the two external ones (see `MANUAL_CASH_KINDS`).
 *
 * `deposit`/`withdrawal` are EXTERNAL — they are the contributions
 * `net_deposits` and the benchmark simulation match. `interest`,
 * `dividend_cash`, `tax` and `fee` move the balance but are NOT contributions:
 * the broker paid you (or charged you) *inside* the account. That is the exact
 * generalization of the existing rule excluding `dividend_reinvestment` from
 * external flows.
 *
 * `dividend_cash` is named that, not `dividend`, so it can never be confused at
 * a glance with `transactions.kind = 'dividend_reinvestment'`.
 *
 * This list is for LABELLING and for the form's options only — it is
 * deliberately NOT used to validate `kind` off the wire; see `cashKindSchema`.
 */
export const CASH_KINDS = [
  'deposit',
  'withdrawal',
  'interest',
  'dividend_cash',
  'tax',
  'fee',
] as const

/** The two kinds the manual entry drawer offers. The importer writes all six. */
export const MANUAL_CASH_KINDS = ['deposit', 'withdrawal'] as const

/** External money in/out — the only kinds that count toward `net_deposits`. */
export const EXTERNAL_CASH_KINDS = ['deposit', 'withdrawal'] as const

export type CashKind = (typeof CASH_KINDS)[number]
export type ManualCashKind = (typeof MANUAL_CASH_KINDS)[number]

/**
 * `kind` is modelled as a PLAIN STRING, not a zod enum — the documented
 * `import.status` precedent (docs/API_SHAPES.md). Schema failures throw in dev,
 * so enumerating a field the backend may extend turns a newer server into a
 * blank page. Consumers label it through `cashKindLabel` in `lib/cash.ts`, which
 * falls through to the raw string for anything it doesn't recognise.
 */
export const cashKindSchema = z.string()

/**
 * One ledger row. `amount` is an UNSIGNED magnitude for the two external kinds
 * (direction is in `kind`); an internal kind may legitimately carry a sign (a
 * dividend reversal, a fee reimbursement), so the schema constrains only that it
 * is a decimal string.
 *
 * `occurred_on`, deliberately NOT `executed_on`: a cash row must never
 * duck-type as a `Transaction` in the services that take injectable arrays and
 * read `.executed_on`. A different name makes an accidental mix a loud failure
 * rather than a wrong dollar figure.
 */
export const cashTransactionSchema = z.object({
  id: z.number(),
  portfolio_id: z.number(),
  kind: cashKindSchema,
  amount: DecimalString,
  occurred_on: IsoDate,
  notes: z.string().nullable(),
  created_at: IsoDateTime,
  updated_at: IsoDateTime,
})

/**
 * The balance snapshot create/update carry so a toast can report the new
 * position immediately. NOTE: on this envelope `cash_balance` is NOT nullable —
 * a row was just written, so the portfolio provably tracks cash. Only
 * `/summary`'s copy of the field is nullable.
 *
 * The entry is NEVER rejected for driving cash negative: an imported broker
 * ledger can legitimately leave a portfolio negative, so it is shown with a
 * warning, not blocked.
 */
export const cashBalanceMetaSchema = z.object({
  cash_balance: DecimalString,
  cash_negative: z.boolean(),
  cash_negative_since: IsoDate.nullable(),
})

/** GET show — the bare row, no balance meta. */
export const cashTransactionResponseSchema = z.object({
  cash_transaction: cashTransactionSchema,
})

/** POST / PATCH — the row plus the balance snapshot. */
export const cashTransactionMutationResponseSchema = z.object({
  cash_transaction: cashTransactionSchema,
  meta: cashBalanceMetaSchema,
})

/** GET index — paginated 50/page, most-recent-first, like /transactions. */
export const cashTransactionsResponseSchema = z.object({
  cash_transactions: z.array(cashTransactionSchema),
  meta: paginationMetaSchema,
})

/**
 * The reporting basis. A closed two-value discriminator that decides which stat
 * tiles exist and how `net_deposits` is computed, so unlike `kind` it IS
 * enumerated: a third basis could not be rendered without frontend work anyway,
 * and failing loudly beats silently mislabelling the denominator.
 */
export const cashBasisSchema = z.enum(['cash', 'trades'])

export type CashBasis = z.infer<typeof cashBasisSchema>
export type CashTransaction = z.infer<typeof cashTransactionSchema>
export type CashBalanceMeta = z.infer<typeof cashBalanceMetaSchema>
export type CashTransactionResponse = z.infer<typeof cashTransactionResponseSchema>
export type CashTransactionMutationResponse = z.infer<
  typeof cashTransactionMutationResponseSchema
>
export type CashTransactionsResponse = z.infer<typeof cashTransactionsResponseSchema>
