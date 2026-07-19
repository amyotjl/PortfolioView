import { shallowRef, watch } from 'vue'
import { defineStore } from 'pinia'

export type Theme = 'light' | 'dark'

const STORAGE_KEY = 'pv-theme'

function initialTheme(): Theme {
  if (typeof window === 'undefined') return 'light'
  const stored = window.localStorage.getItem(STORAGE_KEY)
  if (stored === 'light' || stored === 'dark') return stored
  return window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light'
}

/**
 * Client-owned theme. A single `data-theme` attribute on <html> flips the whole
 * design system — the CSS custom properties in assets/main.css are the shared
 * source of truth for Tailwind, PrimeVue (unstyled), and (later) the ECharts theme.
 * The pre-mount inline script in index.html sets the attribute first to avoid a
 * flash; this store keeps it in sync and persists the choice.
 */
export const useThemeStore = defineStore('theme', () => {
  const theme = shallowRef<Theme>(initialTheme())

  watch(
    theme,
    (value) => {
      if (typeof document !== 'undefined') {
        document.documentElement.setAttribute('data-theme', value)
      }
      if (typeof window !== 'undefined') {
        window.localStorage.setItem(STORAGE_KEY, value)
      }
    },
    { immediate: true },
  )

  function toggle(): void {
    theme.value = theme.value === 'dark' ? 'light' : 'dark'
  }

  function setTheme(next: Theme): void {
    theme.value = next
  }

  return { theme, toggle, setTheme }
})
