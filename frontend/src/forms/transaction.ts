import { z } from 'zod'

/**
 * Client-side schema for the transaction drawer (create + edit).
 *
 * DECIMALS STAY STRINGS. shares/price/fees are `numeric(20,8)`, `numeric(16,6)`
 * and `numeric(12,2)` server-side and cross the wire as JSON strings
 * (docs/API_SHAPES.md). So the form binds them to text inputs and validates the
 * *string*, rather than using a numeric input that would round-trip through
 * IEEE-754 — an 8dp share count is exactly the value a float loses. Nothing here
 * ever calls parseFloat; we only check shape and sign, and hand the untouched
 * string to the API.
 *
 * These rules mirror the server's (Transaction model validations + the
 * transactions CHECK constraints: shares > 0, price > 0, fees >= 0). The server
 * stays authoritative — this is fast feedback, not the gate. In particular the
 * no-short-position rule is deliberately NOT modelled here: it needs a
 * split-adjusted replay of the whole timeline, so it can only be decided by the
 * server, which answers 422 with the first offending date under `base`.
 */

/** Plain decimal, no exponent/sign tricks: `12`, `12.5`, `.5`, `0.00000001`. */
const DECIMAL = /^(?:\d+(?:\.\d*)?|\.\d+)$/

/**
 * Validate a decimal string by shape, then by scale, then by sign — all without
 * arithmetic. Sign is decided by "does it contain a nonzero digit", which is
 * exact for an unsigned decimal and avoids a float comparison entirely.
 */
function decimalField(options: {
  label: string
  scale: number
  allowZero: boolean
}): z.ZodType<string> {
  const { label, scale, allowZero } = options
  return z
    .string()
    .trim()
    .min(1, `${label} is required`)
    .refine((value) => DECIMAL.test(value), `${label} must be a number`)
    .refine((value) => {
      const decimals = value.split('.')[1] ?? ''
      return decimals.length <= scale
    }, `${label} allows at most ${scale} decimal place${scale === 1 ? '' : 's'}`)
    .refine(
      (value) => allowZero || /[1-9]/.test(value),
      `${label} must be greater than zero`,
    )
}

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
