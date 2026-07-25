import { computed, toValue, type MaybeRefOrGetter } from 'vue'
import { useMutation, useQuery, useQueryCache } from '@pinia/colada'
import { apiDelete, apiGet, apiPatch, apiPost } from '@/api/client'
import {
  transactionResponseSchema,
  transactionsResponseSchema,
  type PaginationMeta,
  type Transaction,
} from '@/types'
import { PORTFOLIOS_KEY } from '@/composables/usePortfolios'

/**
 * Transactions are SERVER state and live only in the Pinia Colada cache.
 *
 * CACHE INVALIDATION IS THE LOAD-BEARING PART. Every transaction mutation moves
 * the portfolio's whole derived series: the backend bumps `series_version` on
 * create/update/destroy (Transaction model callback), which invalidates the
 * server-side caches for candles/summary/allocations. The client has to mirror
 * that or the dashboard silently shows pre-mutation numbers. So one shared
 * helper invalidates ALL of it — transactions, candles, summary, allocations,
 * and portfolios (whose payload carries `series_version`, and whose list view
 * renders sparklines).
 *
 * Miss one of these and the bug is invisible in the transactions page itself and
 * only shows up as a stale dashboard, so they are invalidated together in one
 * place rather than per-mutation.
 */
export const TRANSACTIONS_KEY = 'transactions'

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

/**
 * Every cache key a transaction mutation must drop. Keyed by prefix so all
 * pages of the transactions list and every date-range variant of the candles
 * query are covered, not just the currently-mounted one.
 */
function invalidateSeries(cache: ReturnType<typeof useQueryCache>, portfolioId: number): void {
  cache.invalidateQueries({ key: [TRANSACTIONS_KEY, portfolioId] })
  cache.invalidateQueries({ key: ['candles', portfolioId] })
  cache.invalidateQueries({ key: ['summary', portfolioId] })
  cache.invalidateQueries({ key: ['allocations', portfolioId] })
  cache.invalidateQueries({ key: [...PORTFOLIOS_KEY] })
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
    onSuccess: () => invalidateSeries(cache, toValue(portfolioId)),
  })
}

export function useUpdateTransaction(portfolioId: MaybeRefOrGetter<number>) {
  const cache = useQueryCache()
  return useMutation({
    mutation: ({ id, input }: { id: number; input: TransactionInput }) =>
      apiPatch(`/portfolios/${toValue(portfolioId)}/transactions/${id}`, input, {
        schema: transactionResponseSchema,
      }),
    onSuccess: () => invalidateSeries(cache, toValue(portfolioId)),
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
    onSuccess: () => invalidateSeries(cache, toValue(portfolioId)),
  })
}
