import { computed, shallowRef } from 'vue'
import { defineStore } from 'pinia'
import { apiGet } from '@/api/client'
import { sessionSchema, type SessionUser } from '@/types'

export type AuthStatus = 'idle' | 'loading' | 'authenticated' | 'anonymous'

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

  /** Called on sign-out or when the client observes a 401. */
  function clear(): void {
    user.value = null
    status.value = 'anonymous'
  }

  return { user, status, isAuthenticated, bootstrap, setUser, clear }
})
