import { computed, toValue, type MaybeRefOrGetter } from 'vue'
import { useMutation, useQuery, useQueryCache } from '@pinia/colada'
import { apiDelete, apiGet, apiPatch, apiPost } from '@/api/client'
import {
  transactionResponseSchema,
  transactionsResponseSchema,
  type PaginationMeta,
  type Transaction,
} from '@/types'
import {
  TRANSACTIONS_KEY,
  invalidatePortfolioSeries,
} from '@/composables/portfolioSeriesCache'

/**
 * Transactions are SERVER state and live only in the Pinia Colada cache.
 *
 * CACHE INVALIDATION IS THE LOAD-BEARING PART, and it does NOT live here.
 * Every transaction mutation moves the portfolio's whole derived series, and so
 * does every recurring-rule mutation and every cash movement — so the shared list
 * lives in `composables/portfolioSeriesCache.ts` and all three composables call
 * `invalidatePortfolioSeries`. This file used to claim to be "the one place" while
 * `useRecurringTransactions` carried a hand-copied duplicate; #80 made the claim
 * true instead of just written down.
 */
export { TRANSACTIONS_KEY }

export function transactionsKey(
  portfolioId: number,
  page: number,
): [string, number, number] {
  return [TRANSACTIONS_KEY, portfolioId, page]
}

/** Request body for create/update — mirrors the controller's permitted params. */
export interface TransactionInput {
  symbol: string
  side: 'buy' | 'sell'
  kind: 'normal' | 'dividend_reinvestment'
  shares: string
  price: string
  fees: string
  executed_on: string
  notes: string | null
}

export function useTransactionsQuery(
  portfolioId: MaybeRefOrGetter<number>,
  page: MaybeRefOrGetter<number> = 1,
) {
  const query = useQuery({
    key: () => [...transactionsKey(toValue(portfolioId), toValue(page))],
    query: () =>
      apiGet(`/portfolios/${toValue(portfolioId)}/transactions`, {
        query: { page: toValue(page) },
        schema: transactionsResponseSchema,
      }),
    enabled: () => toValue(portfolioId) > 0,
  })

  const transactions = computed<Transaction[]>(() => query.data.value?.transactions ?? [])
  const meta = computed<PaginationMeta | null>(() => query.data.value?.meta ?? null)
  const isEmpty = computed(
    () => query.status.value === 'success' && transactions.value.length === 0,
  )

  return { ...query, transactions, meta, isEmpty }
}

export function useCreateTransaction(portfolioId: MaybeRefOrGetter<number>) {
  const cache = useQueryCache()
  return useMutation({
    mutation: (input: TransactionInput) =>
      apiPost(`/portfolios/${toValue(portfolioId)}/transactions`, input, {
        schema: transactionResponseSchema,
      }),
    onSuccess: () => invalidatePortfolioSeries(cache, toValue(portfolioId)),
  })
}

export function useUpdateTransaction(portfolioId: MaybeRefOrGetter<number>) {
  const cache = useQueryCache()
  return useMutation({
    mutation: ({ id, input }: { id: number; input: TransactionInput }) =>
      apiPatch(`/portfolios/${toValue(portfolioId)}/transactions/${id}`, input, {
        schema: transactionResponseSchema,
      }),
    onSuccess: () => invalidatePortfolioSeries(cache, toValue(portfolioId)),
  })
}

export function useDeleteTransaction(portfolioId: MaybeRefOrGetter<number>) {
  const cache = useQueryCache()
  return useMutation({
    // A destroy that would strand a later sell is rejected by the model's
    // before_destroy replay -> 422 naming the offending date, so callers must
    // surface the error rather than assume success.
    mutation: (id: number) =>
      apiDelete(`/portfolios/${toValue(portfolioId)}/transactions/${id}`),
    onSuccess: () => invalidatePortfolioSeries(cache, toValue(portfolioId)),
  })
}
