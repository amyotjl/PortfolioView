import { z } from 'zod'
import { DecimalString, IsoDate, IsoDateTime } from './common'

/** v1 is buy-only (validated backend-side). */
export const recurringSideSchema = z.enum(['buy'])
export const amountTypeSchema = z.enum(['dollars', 'shares'])
/** Frequencies per docs/PLAN.md; a drift here fails loudly in dev (the point). */
export const recurringFrequencySchema = z.enum([
  'weekly',
  'biweekly',
  'monthly',
  'quarterly',
])

/**
 * Single: { recurring_transaction: {...} }
 * Index:  { recurring_transactions: [...] }
 * dollar_amount / share_amount / end_on / paused_reason are nullable; amounts
 * are decimal strings.
 */
export const recurringTransactionSchema = z.object({
  id: z.number(),
  portfolio_id: z.number(),
  instrument_id: z.number(),
  symbol: z.string(),
  side: recurringSideSchema,
  amount_type: amountTypeSchema,
  dollar_amount: DecimalString.nullable(),
  share_amount: DecimalString.nullable(),
  frequency: recurringFrequencySchema,
  anchor_on: IsoDate,
  next_run_on: IsoDate,
  end_on: IsoDate.nullable(),
  active: z.boolean(),
  paused_reason: z.string().nullable(),
  consecutive_skips: z.number(),
  created_at: IsoDateTime,
  updated_at: IsoDateTime,
})

export const recurringTransactionResponseSchema = z.object({
  recurring_transaction: recurringTransactionSchema,
})

export const recurringTransactionsResponseSchema = z.object({
  recurring_transactions: z.array(recurringTransactionSchema),
})

/**
 * POST .../recurring_transactions/preview ->
 *   { preview: { run_dates: [{ scheduled_for, execution_on }] } }
 * 3 slots, nothing persisted. `execution_on` is null when no trading day is known yet.
 */
export const recurringRunDateSchema = z.object({
  scheduled_for: IsoDate,
  execution_on: IsoDate.nullable(),
})

export const recurringPreviewResponseSchema = z.object({
  preview: z.object({
    run_dates: z.array(recurringRunDateSchema),
  }),
})

export type RecurringSide = z.infer<typeof recurringSideSchema>
export type AmountType = z.infer<typeof amountTypeSchema>
export type RecurringFrequency = z.infer<typeof recurringFrequencySchema>
export type RecurringTransaction = z.infer<typeof recurringTransactionSchema>
export type RecurringTransactionResponse = z.infer<typeof recurringTransactionResponseSchema>
export type RecurringTransactionsResponse = z.infer<typeof recurringTransactionsResponseSchema>
export type RecurringRunDate = z.infer<typeof recurringRunDateSchema>
export type RecurringPreviewResponse = z.infer<typeof recurringPreviewResponseSchema>
