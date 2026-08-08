import { z } from 'zod'
import { decimalField } from './decimalField'

/**
 * Client-side schema for the transaction drawer (create + edit).
 *
 * The decimal-string validator this form is built on now lives in
 * `forms/decimalField.ts` (extracted byte-identical in #80 so the transaction,
 * recurring and cash forms share one copy) — its module note explains why these
 * values never become numbers.
 *
 * These rules mirror the server's (Transaction model validations + the
 * transactions CHECK constraints: shares > 0, price > 0, fees >= 0). The server
 * stays authoritative — this is fast feedback, not the gate. In particular the
 * no-short-position rule is deliberately NOT modelled here: it needs a
 * split-adjusted replay of the whole timeline, so it can only be decided by the
 * server, which answers 422 with the first offending date under `base`.
 */

export const transactionFormSchema = z.object({
  // forceSelection on the AutoComplete means this is always a directory symbol,
  // but it is still validated: the server re-resolves it and can 422 on `symbol`
  // (unknown ticker, or non-USD/non-US-exchange, which v1 rejects).
  symbol: z
    .string()
    .trim()
    .min(1, 'Pick a ticker from the list')
    .max(20, 'That is not a valid ticker')
    .transform((value) => value.toUpperCase()),
  side: z.enum(['buy', 'sell']),
  kind: z.enum(['normal', 'dividend_reinvestment']),
  shares: decimalField({ label: 'Shares', scale: 8, allowZero: false }),
  price: decimalField({ label: 'Price', scale: 6, allowZero: false }),
  fees: decimalField({ label: 'Fees', scale: 2, allowZero: true }),
  executed_on: z.string().regex(/^\d{4}-\d{2}-\d{2}$/, 'Pick a date'),
  // Empty textarea -> null, so we send an explicit "no notes" rather than "".
  notes: z
    .string()
    .max(2000, 'Keep notes under 2000 characters')
    .nullable()
    .transform((value) => (value && value.trim().length > 0 ? value.trim() : null)),
})

export type TransactionFormValues = z.infer<typeof transactionFormSchema>

/** Fields the drawer renders — the allow-list `mapApiError` maps 422 details onto. */
export const TRANSACTION_FORM_FIELDS = [
  'symbol',
  'side',
  'kind',
  'shares',
  'price',
  'fees',
  'executed_on',
  'notes',
] as const

/** A fresh buy, dated today, with fees zeroed rather than blank. */
export function emptyTransactionForm(executedOn: string): TransactionFormValues {
  return {
    symbol: '',
    side: 'buy',
    kind: 'normal',
    shares: '',
    price: '',
    fees: '0',
    executed_on: executedOn,
    notes: null,
  }
}
