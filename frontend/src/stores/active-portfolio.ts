import { shallowRef } from 'vue'
import { defineStore } from 'pinia'

/**
 * Client-owned selection: which portfolio the shell is currently focused on.
 * Only the id lives here — the portfolio records themselves are server state
 * (a Pinia Colada query, added in #039). The router guard keeps this in sync
 * with the `:id` route param.
 */
export const useActivePortfolioStore = defineStore('activePortfolio', () => {
  const activeId = shallowRef<number | null>(null)

  function setActive(id: number | null): void {
    activeId.value = id
  }

  return { activeId, setActive }
})
