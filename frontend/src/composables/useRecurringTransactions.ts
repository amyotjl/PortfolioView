import { computed, shallowRef, toValue, type MaybeRefOrGetter } from 'vue'
import { useMutation, useQuery, useQueryCache } from '@pinia/colada'
import { apiDelete, apiGet, apiPatch, apiPost } from '@/api/client'
import {
  recurringPreviewResponseSchema,
  recurringTransactionResponseSchema,
  recurringTransactionsResponseSchema,
  type RecurringFrequency,
  type RecurringRunDate,
  type RecurringTransaction,
} from '@/types'
import {
  RECURRING_KEY,
  invalidatePortfolioSeries,
} from '@/composables/portfolioSeriesCache'

/**
 * Recurring rules are SERVER state in the Pinia Colada cache, keyed
 * `['recurring', pid]`.
 *
 * Mutations invalidate the same series keys a transaction mutation does: the
 * controller bumps the portfolio's `series_version` on every recurring CRUD
 * (mirroring the Transaction model), so the dashboard's cached candles/summary/
 * allocations are stale afterwards too. Transactions are included because a rule
 * that materializes creates real transactions.
 *
 * That list used to be hand-copied from `useTransactions`; #80 extracted it to
 * `composables/portfolioSeriesCache.ts` so the two (now three) call sites cannot
 * drift apart again.
 */
export { RECURRING_KEY }

/** Request body for create/update — mirrors the controller's permitted params. */
export interface RecurringInput {
  symbol: string
  side: 'buy'
  amount_type: 'dollars' | 'shares'
  dollar_amount: string | null
  share_amount: string | null
  frequency: RecurringFrequency
  anchor_on: string
  end_on: string | null
  active: boolean
}

export function useRecurringQuery(portfolioId: MaybeRefOrGetter<number>) {
  const query = useQuery({
    key: () => [RECURRING_KEY, toValue(portfolioId)],
    query: () =>
      apiGet(`/portfolios/${toValue(portfolioId)}/recurring_transactions`, {
        schema: recurringTransactionsResponseSchema,
      }),
    enabled: () => toValue(portfolioId) > 0,
  })

  const rules = computed<RecurringTransaction[]>(
    () => query.data.value?.recurring_transactions ?? [],
  )
  const isEmpty = computed(() => query.status.value === 'success' && rules.value.length === 0)

  return { ...query, rules, isEmpty }
}

export function useCreateRecurring(portfolioId: MaybeRefOrGetter<number>) {
  const cache = useQueryCache()
  return useMutation({
    mutation: (input: RecurringInput) =>
      apiPost(`/portfolios/${toValue(portfolioId)}/recurring_transactions`, input, {
        schema: recurringTransactionResponseSchema,
      }),
    onSuccess: () => invalidatePortfolioSeries(cache, toValue(portfolioId)),
  })
}

export function useUpdateRecurring(portfolioId: MaybeRefOrGetter<number>) {
  const cache = useQueryCache()
  return useMutation({
    // Also used for pause/resume: PATCH { active } alone is a valid update, and
    // the controller clears paused_reason + consecutive_skips on reactivation.
    mutation: ({ id, input }: { id: number; input: Partial<RecurringInput> }) =>
      apiPatch(`/portfolios/${toValue(portfolioId)}/recurring_transactions/${id}`, input, {
        schema: recurringTransactionResponseSchema,
      }),
    onSuccess: () => invalidatePortfolioSeries(cache, toValue(portfolioId)),
  })
}

export function useDeleteRecurring(portfolioId: MaybeRefOrGetter<number>) {
  const cache = useQueryCache()
  return useMutation({
    // Already-materialized transactions outlive the rule (FK ON DELETE SET NULL),
    // so deleting a rule never rewrites history.
    mutation: (id: number) =>
      apiDelete(`/portfolios/${toValue(portfolioId)}/recurring_transactions/${id}`),
    onSuccess: () => invalidatePortfolioSeries(cache, toValue(portfolioId)),
  })
}

/**
 * Next-3-run-dates preview.
 *
 * A POST that persists nothing (a dry run over frequency + anchor), so it is
 * driven imperatively as the form's inputs change rather than cached as server
 * state — caching every intermediate anchor the user scrolls through would fill
 * the query cache with garbage.
 *
 * Last-write-wins via abort, so a slow earlier response can't overwrite the
 * dates for the inputs now on screen. A 422 (bad frequency/anchor) clears the
 * preview instead of surfacing an error — the form's own validation covers it.
 */
export function useRecurringPreview(portfolioId: MaybeRefOrGetter<number>) {
  const runDates = shallowRef<RecurringRunDate[]>([])
  const isLoading = shallowRef(false)
  let controller: AbortController | null = null

  async function preview(frequency: string, anchorOn: string): Promise<void> {
    controller?.abort()
    const pid = toValue(portfolioId)
    if (!pid || !frequency || !/^\d{4}-\d{2}-\d{2}$/.test(anchorOn)) {
      runDates.value = []
      return
    }

    const current = new AbortController()
    controller = current
    isLoading.value = true
    try {
      const data = await apiPost(
        `/portfolios/${pid}/recurring_transactions/preview`,
        { frequency, anchor_on: anchorOn },
        { schema: recurringPreviewResponseSchema, signal: current.signal },
      )
      if (controller !== current) return
      runDates.value = data.preview.run_dates
    } catch {
      if (controller === current) runDates.value = []
    } finally {
      if (controller === current) isLoading.value = false
    }
  }

  return { runDates, isLoading, preview }
}
