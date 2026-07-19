import { computed } from 'vue'
import { useMutation, useQuery, useQueryCache } from '@pinia/colada'
import { apiDelete, apiGet, apiPatch, apiPost } from '@/api/client'
import { portfolioResponseSchema, portfoliosResponseSchema, type Portfolio } from '@/types'

/**
 * Portfolios are SERVER state and live only in the Pinia Colada cache (never a
 * hand-rolled store, per docs/PLAN.md). The list is one query keyed by
 * `['portfolios']`; every create/update/delete mutation invalidates that key so
 * the list (and the top-bar switcher, which shares the key) refetches.
 */
export const PORTFOLIOS_KEY = ['portfolios'] as const

/** Request body for create/update. Mirrors the permitted params (name, benchmark_id). */
export interface PortfolioInput {
  name: string
  benchmark_id: number | null
}

export function usePortfoliosQuery() {
  const query = useQuery({
    key: () => [...PORTFOLIOS_KEY],
    query: () => apiGet('/portfolios', { schema: portfoliosResponseSchema }),
  })

  const portfolios = computed<Portfolio[]>(() => query.data.value?.portfolios ?? [])
  const isEmpty = computed(() => query.status.value === 'success' && portfolios.value.length === 0)

  return { ...query, portfolios, isEmpty }
}

export function useCreatePortfolio() {
  const cache = useQueryCache()
  return useMutation({
    mutation: (input: PortfolioInput) =>
      apiPost('/portfolios', input, { schema: portfolioResponseSchema }),
    onSuccess: () => cache.invalidateQueries({ key: [...PORTFOLIOS_KEY] }),
  })
}

export function useUpdatePortfolio() {
  const cache = useQueryCache()
  return useMutation({
    mutation: ({ id, input }: { id: number; input: PortfolioInput }) =>
      apiPatch(`/portfolios/${id}`, input, { schema: portfolioResponseSchema }),
    onSuccess: () => cache.invalidateQueries({ key: [...PORTFOLIOS_KEY] }),
  })
}

export function useDeletePortfolio() {
  const cache = useQueryCache()
  return useMutation({
    mutation: (id: number) => apiDelete(`/portfolios/${id}`),
    onSuccess: () => cache.invalidateQueries({ key: [...PORTFOLIOS_KEY] }),
  })
}
