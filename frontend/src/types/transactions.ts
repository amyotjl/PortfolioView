import { z } from 'zod'
import { DecimalString, IsoDate, IsoDateTime } from './common'

export const transactionSideSchema = z.enum(['buy', 'sell'])
export const transactionKindSchema = z.enum(['normal', 'dividend_reinvestment'])

/**
 * Single: { transaction: {...} }
 * Index:  { transactions: [...], meta: { page, per_page, total_count, total_pages } }
 *         (default 50/page, max 100, most-recent-first).
 * shares/price/fees are decimal strings; notes and recurring_transaction_id are nullable.
 */
export const transactionSchema = z.object({
  id: z.number(),
  portfolio_id: z.number(),
  instrument_id: z.number(),
  symbol: z.string(),
  side: transactionSideSchema,
  kind: transactionKindSchema,
  shares: DecimalString,
  price: DecimalString,
  fees: DecimalString,
  executed_on: IsoDate,
  notes: z.string().nullable(),
  recurring_transaction_id: z.number().nullable(),
  created_at: IsoDateTime,
  updated_at: IsoDateTime,
})

export const paginationMetaSchema = z.object({
  page: z.number(),
  per_page: z.number(),
  total_count: z.number(),
  total_pages: z.number(),
})

export const transactionResponseSchema = z.object({
  transaction: transactionSchema,
})

export const transactionsResponseSchema = z.object({
  transactions: z.array(transactionSchema),
  meta: paginationMetaSchema,
})

export type TransactionSide = z.infer<typeof transactionSideSchema>
export type TransactionKind = z.infer<typeof transactionKindSchema>
export type Transaction = z.infer<typeof transactionSchema>
export type PaginationMeta = z.infer<typeof paginationMetaSchema>
export type TransactionResponse = z.infer<typeof transactionResponseSchema>
export type TransactionsResponse = z.infer<typeof transactionsResponseSchema>
