import { beforeEach, describe, expect, it, vi } from 'vitest'
import { defineComponent, h, nextTick } from 'vue'
import { render, waitFor } from '@testing-library/vue'
import { createPinia, setActivePinia } from 'pinia'
import { PiniaColada, useQueryCache } from '@pinia/colada'

/**
 * INDEPENDENT TESTER GATE for issue #57 — coverage the branch shipped without.
 *
 * Two mutation probes survived the whole 291-test suite untouched:
 *   P5  deleting `cache.invalidateQueries` from useTriggerSync's onSuccess
 *   P7  deleting `enabled: () => auth.isAuthenticated` from useSyncStatusQuery
 * Both left 304/304 green. P7 is the documented M5/M6 trap (a signed-out probe
 * of an authenticated endpoint fires the 401 handler and bounces the visitor to
 * /login, which is how /register became unreachable by URL). No composable in
 * this repo has a test, so the gap is repo-wide rather than #57-specific — but
 * it is this composable's two load-bearing lines, so it is closed here.
 */

const apiGet = vi.fn()
const apiPost = vi.fn()

vi.mock('@/api/client', async () => {
  const actual = await vi.importActual<typeof import('@/api/client')>('@/api/client')
  return { ...actual, apiGet: (...a: unknown[]) => apiGet(...a), apiPost: (...a: unknown[]) => apiPost(...a) }
})

const isAuthenticated = { value: false }
vi.mock('@/stores/auth', () => ({
  useAuthStore: () => ({
    get isAuthenticated() {
      return isAuthenticated.value
    },
  }),
}))

/** Live capture: GET /api/v1/sync, populated cache. */
const LIVE_GET = {
  sync: {
    latest_price_on: '2026-07-30',
    last_trading_day: '2026-07-30',
    stale: false,
    instruments_behind: 0,
    pending: false,
    requested_at: null,
  },
}
/** Live capture: POST /api/v1/sync, 202. */
const LIVE_POST = { sync: { status: 'enqueued', requested_at: '2026-07-31T02:53:39Z' } }

function mountWith(setup: () => void) {
  const Host = defineComponent({
    setup() {
      setup()
      return () => h('div')
    },
  })
  return render(Host, { global: { plugins: [createPinia(), PiniaColada] } })
}

describe('gate #57 — useSync composable', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    setActivePinia(createPinia())
    isAuthenticated.value = false
    apiGet.mockResolvedValue(LIVE_GET)
    apiPost.mockResolvedValue(LIVE_POST)
  })

  it('does NOT probe /sync while signed out (the /register-unreachable trap)', async () => {
    const { useSyncStatusQuery } = await import('./useSync')
    mountWith(() => {
      useSyncStatusQuery()
    })

    await nextTick()
    await new Promise((r) => setTimeout(r, 20))
    expect(apiGet).not.toHaveBeenCalled()
  })

  it('fetches /sync once authenticated, and validates through the GET schema', async () => {
    isAuthenticated.value = true
    const { useSyncStatusQuery } = await import('./useSync')
    let snapshot: ReturnType<typeof useSyncStatusQuery> | null = null
    mountWith(() => {
      snapshot = useSyncStatusQuery()
    })

    await waitFor(() => expect(apiGet).toHaveBeenCalled())
    expect(apiGet.mock.calls[0][0]).toBe('/sync')
    // The schema is passed to the client, not applied after the fact.
    expect(apiGet.mock.calls[0][1]).toHaveProperty('schema')
    await waitFor(() => expect(snapshot!.sync.value?.latest_price_on).toBe('2026-07-30'))
  })

  it('invalidates the freshness query after a successful trigger (probe P5)', async () => {
    isAuthenticated.value = true
    const { useTriggerSync, SYNC_KEY } = await import('./useSync')

    let trigger: ReturnType<typeof useTriggerSync> | null = null
    let invalidate: ReturnType<typeof vi.spyOn> | null = null
    mountWith(() => {
      const cache = useQueryCache()
      invalidate = vi.spyOn(cache, 'invalidateQueries')
      trigger = useTriggerSync()
    })

    const result = await trigger!.mutateAsync()

    expect(apiPost).toHaveBeenCalledWith('/sync', undefined, expect.objectContaining({ schema: expect.anything() }))
    // Unwrapped from the envelope for the caller.
    expect(result).toEqual({ status: 'enqueued', requested_at: '2026-07-31T02:53:39Z' })
    expect(invalidate!).toHaveBeenCalledWith({ key: [...SYNC_KEY] })
  })

  it('does not invalidate when the trigger fails', async () => {
    isAuthenticated.value = true
    apiPost.mockRejectedValue(new Error('boom'))
    const { useTriggerSync } = await import('./useSync')

    let trigger: ReturnType<typeof useTriggerSync> | null = null
    let invalidate: ReturnType<typeof vi.spyOn> | null = null
    mountWith(() => {
      const cache = useQueryCache()
      invalidate = vi.spyOn(cache, 'invalidateQueries')
      trigger = useTriggerSync()
    })

    await expect(trigger!.mutateAsync()).rejects.toThrow('boom')
    expect(invalidate!).not.toHaveBeenCalled()
  })

  it('keys the query globally — no portfolio id (the cache is shared)', async () => {
    const { SYNC_KEY } = await import('./useSync')
    expect([...SYNC_KEY]).toEqual(['sync'])
  })
})
