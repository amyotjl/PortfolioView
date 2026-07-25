import { computed } from 'vue'
import { useMutation, useQuery, useQueryCache } from '@pinia/colada'
import { apiDelete, apiGet, apiPatch, apiPost } from '@/api/client'
import { portfolioResponseSchema, portfoliosResponseSchema, type Portfolio } from '@/types'
import { useAuthStore } from '@/stores/auth'

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
  const auth = useAuthStore()

  const query = useQuery({
    key: () => [...PORTFOLIOS_KEY],
    query: () => apiGet('/portfolios', { schema: portfoliosResponseSchema }),
    /**
     * /portfolios is authenticated-only, so never probe it while anonymous.
     *
     * This guard is load-bearing, not defensive dressing. PortfolioSwitcher (in
     * the AppShell top bar) calls this composable, and App.vue falls back to
     * AppShell until the async router guard resolves `route.meta`. Without the
     * guard, loading /register or /login directly fired this query while signed
     * out and the resulting 401 hit the client's unauthorized handler, which
     * pushed the visitor to /login?redirect=/ — making the register page
     * unreachable by URL. Found by the e2e smoke suite (#51).
     */
    enabled: () => auth.isAuthenticated,
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
