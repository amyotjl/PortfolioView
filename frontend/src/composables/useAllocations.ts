import { computed, toValue, type MaybeRefOrGetter } from 'vue'
import { useQuery } from '@pinia/colada'
import { apiGet } from '@/api/client'
import { allocationsResponseSchema, type Allocations } from '@/types'

/**
 * Current allocation breakdown (GET /portfolios/:id/allocations), server state
 * keyed `['allocations', pid]`. Like /summary this is an as-of-latest snapshot,
 * independent of the dashboard's date-range window.
 */
export function useAllocationsQuery(portfolioId: MaybeRefOrGetter<number>) {
  const query = useQuery({
    key: () => ['allocations', toValue(portfolioId)],
    query: () =>
      apiGet(`/portfolios/${toValue(portfolioId)}/allocations`, {
        schema: allocationsResponseSchema,
      }),
    enabled: () => toValue(portfolioId) > 0,
  })

  const allocations = computed<Allocations | null>(() => query.data.value?.allocations ?? null)

  return { ...query, allocations }
}
