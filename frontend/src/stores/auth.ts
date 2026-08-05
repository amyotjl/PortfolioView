import { computed, shallowRef } from 'vue'
import { defineStore } from 'pinia'
import { useMutationCache, useQueryCache } from '@pinia/colada'
import { apiGet } from '@/api/client'
import { sessionSchema, type SessionUser } from '@/types'

export type AuthStatus = 'idle' | 'loading' | 'authenticated' | 'anonymous'

/**
 * Drops every cached server response, so nothing survives a session boundary.
 *
 * `cancelQueries()` comes first, and NO TEST PINS IT — measured: deleting that
 * line leaves all four specs in `auth.spec.ts` green, including the in-flight
 * one. Removal alone already closes the disclosure, because a fetch that
 * settles late writes into an entry that is no longer in the map and so can
 * never be served to the next mount. It is kept anyway for a different reason:
 * at the moment `clear()` runs the signed-out page is still mounted (the router
 * push happens after), so an un-aborted request will land a 401, fire the
 * unauthorized handler, and push a redundant /login navigation carrying the old
 * page as `redirect`. Aborting is the correct behaviour on a session boundary;
 * it is not what makes the cache safe. Don't upgrade this comment to
 * "load-bearing" without a probe that discriminates it.
 *
 * There is no `cache.clear()` in @pinia/colada 1.4.2 (issue #73 assumed one) —
 * `getEntries()` with no filter returns every entry and `remove()` drops it,
 * which is the documented surface. The mutation cache is emptied too: a
 * mutation entry holds its last response (an import report, a created
 * transaction), which is the outgoing user's data just as much as a query's is.
 *
 * Resolved lazily inside the function rather than at store-setup time so the
 * auth store keeps no construction-order dependency on the Colada plugin.
 */
function discardServerState(): void {
  const queries = useQueryCache()
  queries.cancelQueries()
  for (const entry of queries.getEntries()) queries.remove(entry)

  const mutations = useMutationCache()
  for (const entry of mutations.getEntries()) mutations.remove(entry)
}

/**
 * Client-owned session state. This is one of the few genuinely client-owned
 * stores allowed by PLAN.md — the current user identity, not cached server
 * collections (those live in Pinia Colada query caches).
 *
 * The router guard calls `bootstrap()` once on first navigation; it probes
 * GET /session with `redirectOnUnauthorized: false` so a signed-out visitor
 * resolves to `anonymous` instead of bouncing through the login redirect.
 */
export const useAuthStore = defineStore('auth', () => {
  const user = shallowRef<SessionUser | null>(null)
  const status = shallowRef<AuthStatus>('idle')

  const isAuthenticated = computed(() => user.value !== null)

  async function bootstrap(): Promise<void> {
    if (status.value !== 'idle') return
    status.value = 'loading'
    try {
      const data = await apiGet('/session', {
        schema: sessionSchema,
        redirectOnUnauthorized: false,
      })
      user.value = data.user
      status.value = 'authenticated'
    } catch {
      user.value = null
      status.value = 'anonymous'
    }
  }

  /** Called by the login/register flows (issue #038) after a successful auth. */
  function setUser(next: SessionUser): void {
    user.value = next
    status.value = 'authenticated'
  }

  /**
   * Called on sign-out or when the client observes a 401.
   *
   * Emptying the server-state caches is PART OF ending a session, not a
   * separate follow-up step. No query key carries a user id — they are
   * `['portfolios']`, `['summary', pid]`, `['candles', pid, …]` — so an entry
   * cached for user A stays valid-looking after A signs out and is served to
   * whoever signs in next in the same tab. Measured on a real production stack
   * during #58: A signs out, B signs in with no page reload, and B renders A's
   * portfolio card (#73).
   *
   * Server authorization was never involved — every endpoint is scoped to
   * `Current.user` and cross-user requests still 404. This is purely what the
   * client re-renders out of a cache it never emptied, which a full page reload
   * masks; that is why normal use never hit it.
   *
   * It lives HERE rather than at the call sites because a session can end two
   * ways — the Sign out button and the 401 handler in `main.ts` — and only the
   * first is the obvious one to remember.
   */
  function clear(): void {
    user.value = null
    status.value = 'anonymous'
    discardServerState()
  }

  return { user, status, isAuthenticated, bootstrap, setUser, clear }
})
