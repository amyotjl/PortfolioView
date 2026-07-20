import { computed, toValue, type MaybeRefOrGetter } from 'vue'
import { useQuery } from '@pinia/colada'
import { apiGet } from '@/api/client'
import { summaryResponseSchema, type Summary } from '@/types'

/**
 * Lifetime stat-tile figures (GET /portfolios/:id/summary), server state keyed
 * `['summary', pid]`. These are LIFETIME numbers — deliberately independent of
 * the dashboard's date-range window, so the tiles are never derived from a
 * windowed candles payload (docs/PLAN.md).
 */
export function useSummaryQuery(portfolioId: MaybeRefOrGetter<number>) {
  const query = useQuery({
    key: () => ['summary', toValue(portfolioId)],
    query: () =>
      apiGet(`/portfolios/${toValue(portfolioId)}/summary`, { schema: summaryResponseSchema }),
    enabled: () => toValue(portfolioId) > 0,
  })

  const summary = computed<Summary | null>(() => query.data.value?.summary ?? null)

  return { ...query, summary }
}
