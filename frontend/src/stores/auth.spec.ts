import { beforeEach, describe, expect, it, vi } from 'vitest'
import { defineComponent, h } from 'vue'
import { render, waitFor } from '@testing-library/vue'
import { createPinia } from 'pinia'
import { PiniaColada, useQueryCache } from '@pinia/colada'
import { usePortfoliosQuery } from '@/composables/usePortfolios'
import { useAuthStore } from '@/stores/auth'

/**
 * Issue #73 — signing out must not leave the previous user's data readable by
 * whoever signs in next in the same tab.
 *
 * THESE TESTS DELIBERATELY DO NOT ASSERT THAT `clear()` CALLS ANYTHING.
 * An "it empties the cache" test that spies on `queryCache.remove` passes for a
 * fix that removes the wrong entries, and passes for a fix that removes them
 * after the next user's component has already rendered. The defect is *what the
 * second user sees*, so that is what is asserted: a fresh mount after a session
 * ends renders no rows at all, rather than the outgoing user's.
 *
 * The mount → unmount → mount shape is not incidental either — it is the
 * reported reproduction (A signs out, the router leaves the page, B signs in
 * and navigates back with NO page reload, which is exactly what masks the bug
 * in normal use).
 */

const apiGet = vi.fn()

vi.mock('@/api/client', async () => {
  const actual = await vi.importActual<typeof import('@/api/client')>('@/api/client')
  return { ...actual, apiGet: (...a: unknown[]) => apiGet(...a) }
})

const A_PORTFOLIOS = { portfolios: [{ id: 1, name: "Alice's TFSA", benchmark_id: null }] }
const B_PORTFOLIOS = { portfolios: [{ id: 2, name: "Bob's RRSP", benchmark_id: null }] }

/**
 * One pinia + Colada instance shared by every mount in a test, so the query
 * cache survives unmounting exactly as it does in the running SPA (a router
 * navigation tears down components, not the plugin).
 */
function harness() {
  const pinia = createPinia()
  const plugins = [pinia, PiniaColada]

  /** Mounts a component that reads the portfolios query, and records its rows. */
  function mountPortfolios() {
    const seen: string[][] = []
    const Host = defineComponent({
      setup() {
        // The query is `enabled` only while authenticated (the documented
        // M5/M6 trap), so the store has to believe someone is signed in.
        useAuthStore().setUser({ id: 1, email_address: 'someone@example.com' })
        const q = usePortfoliosQuery()
        return () => {
          seen.push(q.portfolios.value.map((p) => p.name))
          return h(
            'div',
            q.portfolios.value.map((p) => h('span', p.name)),
          )
        }
      },
    })
    return { ...render(Host, { global: { plugins } }), seen }
  }

  return { pinia, mountPortfolios }
}

describe('ending a session and the server-state cache', () => {
  beforeEach(() => {
    apiGet.mockReset()
  })

  it('does not serve the previous user’s portfolios to the next mount', async () => {
    const { pinia, mountPortfolios } = harness()

    // 1. User A loads their portfolios.
    apiGet.mockResolvedValue(A_PORTFOLIOS)
    const first = mountPortfolios()
    await waitFor(() => expect(first.getByText("Alice's TFSA")).toBeTruthy())

    // 2. A signs out; the router leaves the page, so the component unmounts.
    first.unmount()
    useAuthStore(pinia).clear()

    // 3. B signs in and navigates back. The request is left HANGING on purpose:
    //    any row that renders now can only have come from the cache, so the
    //    assertion cannot be satisfied by a fast refetch.
    apiGet.mockImplementation(() => new Promise(() => {}))
    const second = mountPortfolios()
    await waitFor(() => expect(second.seen.length).toBeGreaterThan(0))

    expect(second.seen.flat()).toEqual([])
    expect(second.queryByText("Alice's TFSA")).toBeNull()
  })

  it('serves the next user their OWN portfolios (the fix does not just break the cache)', async () => {
    const { pinia, mountPortfolios } = harness()

    apiGet.mockResolvedValue(A_PORTFOLIOS)
    const first = mountPortfolios()
    await waitFor(() => expect(first.getByText("Alice's TFSA")).toBeTruthy())
    first.unmount()
    useAuthStore(pinia).clear()

    apiGet.mockResolvedValue(B_PORTFOLIOS)
    const second = mountPortfolios()
    await waitFor(() => expect(second.getByText("Bob's RRSP")).toBeTruthy())
    expect(second.queryByText("Alice's TFSA")).toBeNull()
  })

  /**
   * The 401 path is the same `clear()`, but it is reached from `main.ts` rather
   * than from the Sign out button, and #73's acceptance criteria call it out
   * separately — a session that expires mid-use must not leave the cache
   * readable either.
   */
  it('is emptied when the session ends without a sign-out click', async () => {
    const { pinia, mountPortfolios } = harness()

    apiGet.mockResolvedValue(A_PORTFOLIOS)
    const first = mountPortfolios()
    await waitFor(() => expect(first.getByText("Alice's TFSA")).toBeTruthy())
    expect(useQueryCache(pinia).getEntries().length).toBeGreaterThan(0)

    // What main.ts's unauthorized handler does when any call 401s.
    useAuthStore(pinia).clear()

    expect(useQueryCache(pinia).getEntries()).toEqual([])
  })
})
