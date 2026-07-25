import { z } from 'zod'
import type { RecurringInput } from '@/composables/useRecurringTransactions'

/**
 * Client-side schema for the recurring-rule drawer.
 *
 * v1 IS BUY-ONLY. The RecurringTransaction model rejects a sell rule with a 422
 * on `side` (verified live), so the form offers no side control at all rather
 * than showing an option that always fails.
 *
 * Amounts stay decimal STRINGS for the same reason as the transaction form (see
 * forms/transaction.ts): dollar_amount/share_amount are numeric columns
 * serialized as JSON strings, and a numeric input would round-trip them through
 * IEEE-754.
 *
 * The dollars/shares mode is modelled as a discriminated pair rather than two
 * always-required amounts: whichever mode is active must be present and
 * positive, and the other is sent as null so the server stores exactly one.
 */

const DECIMAL = /^(?:\d+(?:\.\d*)?|\.\d+)$/

export const recurringFrequencies = ['weekly', 'biweekly', 'monthly', 'quarterly'] as const

function amountField(label: string, scale: number) {
  return z
    .string()
    .trim()
    .min(1, `${label} is required`)
    .refine((value) => DECIMAL.test(value), `${label} must be a number`)
    .refine(
      (value) => (value.split('.')[1] ?? '').length <= scale,
      `${label} allows at most ${scale} decimal place${scale === 1 ? '' : 's'}`,
    )
    .refine((value) => /[1-9]/.test(value), `${label} must be greater than zero`)
}

export const recurringFormSchema = z
  .object({
    symbol: z
      .string()
      .trim()
      .min(1, 'Pick a ticker from the list')
      .max(20, 'That is not a valid ticker')
      .transform((value) => value.toUpperCase()),
    amount_type: z.enum(['dollars', 'shares']),
    // Both are optional at the field level; the superRefine below requires the
    // one matching the active mode, so switching modes never leaves a stale
    // error on the hidden field.
    dollar_amount: z.string().nullable(),
    share_amount: z.string().nullable(),
    frequency: z.enum(recurringFrequencies),
    anchor_on: z.string().regex(/^\d{4}-\d{2}-\d{2}$/, 'Pick a start date'),
    end_on: z
      .string()
      .regex(/^\d{4}-\d{2}-\d{2}$/, 'Pick a valid end date')
      .nullable()
      .or(z.literal('').transform(() => null)),
    active: z.boolean(),
  })
  .superRefine((values, ctx) => {
    const field = values.amount_type === 'dollars' ? 'dollar_amount' : 'share_amount'
    const label = values.amount_type === 'dollars' ? 'Amount' : 'Shares'
    const scale = values.amount_type === 'dollars' ? 2 : 8
    const result = amountField(label, scale).safeParse(values[field] ?? '')

    if (!result.success) {
      ctx.addIssue({
        code: 'custom',
        path: [field],
        message: result.error.issues[0]?.message ?? `${label} is invalid`,
      })
    }

    // An end date on or before the start would schedule nothing at all. String
    // comparison is correct for zero-padded ISO dates.
    if (values.end_on && values.end_on <= values.anchor_on) {
      ctx.addIssue({
        code: 'custom',
        path: ['end_on'],
        message: 'End date must be after the start date',
      })
    }
  })

export type RecurringFormValues = z.infer<typeof recurringFormSchema>

/** Fields the drawer renders — the allow-list `mapApiError` maps 422 details onto. */
export const RECURRING_FORM_FIELDS = [
  'symbol',
  'amount_type',
  'dollar_amount',
  'share_amount',
  'frequency',
  'anchor_on',
  'end_on',
  'active',
] as const

export function emptyRecurringForm(anchorOn: string): RecurringFormValues {
  return {
    symbol: '',
    amount_type: 'dollars',
    dollar_amount: '',
    share_amount: null,
    frequency: 'monthly',
    anchor_on: anchorOn,
    end_on: null,
    active: true,
  }
}

/**
 * Form values -> request body. Nulls the amount for the inactive mode so the
 * server persists exactly one, and pins `side` to the only value v1 accepts.
 */
export function toRecurringInput(values: RecurringFormValues): RecurringInput {
  const isDollars = values.amount_type === 'dollars'
  return {
    symbol: values.symbol,
    side: 'buy',
    amount_type: values.amount_type,
    dollar_amount: isDollars ? (values.dollar_amount ?? null) : null,
    share_amount: isDollars ? null : (values.share_amount ?? null),
    frequency: values.frequency,
    anchor_on: values.anchor_on,
    end_on: values.end_on,
    active: values.active,
  }
}
