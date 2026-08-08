import { computed, toValue, type MaybeRefOrGetter } from 'vue'
import { useMutation, useQuery, useQueryCache } from '@pinia/colada'
import { apiDelete, apiGet, apiPatch, apiPost } from '@/api/client'
import {
  cashTransactionMutationResponseSchema,
  cashTransactionsResponseSchema,
  type CashTransaction,
  type PaginationMeta,
} from '@/types'
import { CASH_KEY, invalidatePortfolioSeries } from '@/composables/portfolioSeriesCache'

/**
 * Cash movements are SERVER state and live only in the Pinia Colada cache, keyed
 * `['cash', pid, page]` (issue #80).
 *
 * Its own endpoint, deliberately not merged into `/transactions`: the trade row
 * shape has non-null `symbol`/`side`/`shares`/`price`, so a union there would
 * throw in every consumer's zod schema in dev and force guards into
 * `TransactionsTable`, `buildInstrumentIdMap`, `toOptimisticRow` and
 * `sellPreflightMessage`.
 *
 * Two paginated tables rather than one merged ledger, for an honest reason: both
 * lists page at 50, and page 1 of trades ∪ page 1 of cash is NOT the 50 most
 * recent ledger events. Making that correct means a new merged-ledger endpoint
 * duplicating two working ones, so the two tables sit on the same page (a "why is
 * my cash negative?" investigation stays on one screen) with separate pagination.
 *
 * Invalidation goes through the shared `invalidatePortfolioSeries` — see that
 * module for the full list of figures a single cash row moves.
 */
export { CASH_KEY }

export function cashKey(portfolioId: number, page: number): [string, number, number] {
  return [CASH_KEY, portfolioId, page]
}

/** Request body for create/update — mirrors the controller's permitted params. */
export interface CashInput {
  /** `deposit` | `withdrawal` from the drawer; the importer writes four more. */
  kind: string
  /**
   * SIGNED, always — positive for a `deposit`, negative for a `withdrawal`. An
   * unsigned body is a 422 on `amount`. The drawer's form is unsigned and
   * `forms/cash.ts`'s `toCashInput` applies the sign; nothing should build this
   * object by hand from form values.
   */
  amount: string
  occurred_on: string
  notes: string | null
}

export function useCashQuery(
  portfolioId: MaybeRefOrGetter<number>,
  page: MaybeRefOrGetter<number> = 1,
) {
  const query = useQuery({
    key: () => [...cashKey(toValue(portfolioId), toValue(page))],
    query: () =>
      apiGet(`/portfolios/${toValue(portfolioId)}/cash_transactions`, {
        query: { page: toValue(page) },
        schema: cashTransactionsResponseSchema,
      }),
    enabled: () => toValue(portfolioId) > 0,
  })

  const cashTransactions = computed<CashTransaction[]>(
    () => query.data.value?.cash_transactions ?? [],
  )
  const meta = computed<PaginationMeta | null>(() => query.data.value?.meta ?? null)
  const isEmpty = computed(
    () => query.status.value === 'success' && cashTransactions.value.length === 0,
  )

  return { ...query, cashTransactions, meta, isEmpty }
}

/**
 * Create.
 *
 * The response carries a balance snapshot in `meta` so a toast can report the new
 * position immediately. A withdrawal that drives the balance negative is NOT
 * rejected — negative cash is legal (an imported broker ledger can legitimately
 * leave a portfolio there) and is surfaced as an advisory, never as a 422.
 */
export function useCreateCashTransaction(portfolioId: MaybeRefOrGetter<number>) {
  const cache = useQueryCache()
  return useMutation({
    mutation: (input: CashInput) =>
      apiPost(`/portfolios/${toValue(portfolioId)}/cash_transactions`, input, {
        schema: cashTransactionMutationResponseSchema,
      }),
    onSuccess: () => invalidatePortfolioSeries(cache, toValue(portfolioId)),
  })
}

export function useUpdateCashTransaction(portfolioId: MaybeRefOrGetter<number>) {
  const cache = useQueryCache()
  return useMutation({
    mutation: ({ id, input }: { id: number; input: CashInput }) =>
      apiPatch(`/portfolios/${toValue(portfolioId)}/cash_transactions/${id}`, input, {
        schema: cashTransactionMutationResponseSchema,
      }),
    onSuccess: () => invalidatePortfolioSeries(cache, toValue(portfolioId)),
  })
}

/**
 * Delete -> 204, no body.
 *
 * Unlike a trade delete there is no position replay that can refuse it: a cash row
 * cannot strand a later sell. It can leave the balance negative, which is allowed.
 */
export function useDeleteCashTransaction(portfolioId: MaybeRefOrGetter<number>) {
  const cache = useQueryCache()
  return useMutation({
    mutation: (id: number) =>
      apiDelete(`/portfolios/${toValue(portfolioId)}/cash_transactions/${id}`),
    onSuccess: () => invalidatePortfolioSeries(cache, toValue(portfolioId)),
  })
}
