<script setup lang="ts">
import { storeToRefs } from 'pinia'
import SyncCard from '@/components/settings/SyncCard.vue'
import { useThemeStore, type Theme } from '@/stores/theme'

const themeStore = useThemeStore()
const { theme } = storeToRefs(themeStore)

const options: { value: Theme; label: string }[] = [
  { value: 'light', label: 'Light' },
  { value: 'dark', label: 'Dark' },
]
</script>

<template>
  <section>
    <header class="mb-6">
      <h1 class="text-xl font-semibold tracking-tight text-ink">Settings</h1>
      <p class="mt-1 text-sm text-ink-muted">No currency selector in v1 — the backend is USD-only.</p>
    </header>

    <div class="flex max-w-xl flex-col gap-6">
      <div class="rounded-lg border border-line bg-panel p-6">
        <h2 class="text-sm font-semibold text-ink">Appearance</h2>
        <p class="mt-1 text-sm text-ink-muted">Choose how PortfolioView looks.</p>

        <div
          class="mt-4 inline-flex rounded-md border border-line p-1"
          role="group"
          aria-label="Theme"
        >
          <button
            v-for="option in options"
            :key="option.value"
            type="button"
            class="rounded px-3 py-1.5 text-sm font-medium transition-colors"
            :class="
              theme === option.value
                ? 'bg-accent text-on-accent'
                : 'text-ink-muted hover:text-ink'
            "
            :aria-pressed="theme === option.value"
            @click="themeStore.setTheme(option.value)"
          >
            {{ option.label }}
          </button>
        </div>
      </div>

      <SyncCard />
    </div>
  </section>
</template>
