import { computed } from 'vue'
import { useMutation, useQuery, useQueryCache } from '@pinia/colada'
import { apiGet, apiPost } from '@/api/client'
import { syncStatusResponseSchema, syncTriggerResponseSchema } from '@/types'
import type { SyncStatusSnapshot, SyncTriggerResult } from '@/types'
import { useAuthStore } from '@/stores/auth'

/**
 * Price-cache sync (issue #57). Server state, so it lives only in the Pinia
 * Colada cache — never a hand-rolled store.
 *
 * The key carries NO portfolio id: `/sync` is global (the price cache is shared
 * by every portfolio), which is exactly why Settings renders it and the
 * portfolio-scoped `/summary.as_of` does not.
 */
export const SYNC_KEY = ['sync'] as const

export function useSyncStatusQuery() {
  const auth = useAuthStore()

  const query = useQuery({
    key: () => [...SYNC_KEY],
    query: () => apiGet('/sync', { schema: syncStatusResponseSchema }),
    // Same guard as usePortfoliosQuery: an authenticated-only endpoint must
    // never be probed while signed out, or its 401 fires the client's
    // unauthorized handler and bounces the visitor to /login.
    enabled: () => auth.isAuthenticated,
  })

  const sync = computed<SyncStatusSnapshot | null>(() => query.data.value?.sync ?? null)

  return { ...query, sync }
}

/**
 * POST /api/v1/sync — no body, no params; the session cookie plus the CSRF
 * header the fetch client already attaches are the whole request.
 *
 * On success the freshness snapshot is invalidated so the card immediately
 * reflects the claim the trigger just took (`pending: true`).
 */
export function useTriggerSync() {
  const cache = useQueryCache()

  return useMutation({
    mutation: async (): Promise<SyncTriggerResult> => {
      const response = await apiPost('/sync', undefined, { schema: syncTriggerResponseSchema })
      return response.sync
    },
    onSuccess: () => {
      cache.invalidateQueries({ key: [...SYNC_KEY] })
    },
  })
}
