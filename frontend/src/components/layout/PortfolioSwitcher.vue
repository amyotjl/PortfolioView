<script setup lang="ts">
import { computed, shallowRef } from 'vue'
import { storeToRefs } from 'pinia'
import { useActivePortfolioStore } from '@/stores/active-portfolio'
import { usePortfoliosQuery } from '@/composables/usePortfolios'

/**
 * Top-bar portfolio switcher, backed by the shared `['portfolios']` Colada query
 * (no separate fetch). Shows the active portfolio's real name and opens a menu to
 * jump between portfolios or back to the full list.
 */
const { activeId } = storeToRefs(useActivePortfolioStore())
const { portfolios } = usePortfoliosQuery()

const open = shallowRef(false)
const activePortfolio = computed(() => portfolios.value.find((p) => p.id === activeId.value) ?? null)
const label = computed(() => activePortfolio.value?.name ?? 'All portfolios')

function close() {
  open.value = false
}
</script>

<template>
  <div class="relative" @keydown.escape="close">
    <button
      type="button"
      class="inline-flex items-center gap-2 rounded-md border border-line bg-panel px-3 py-1.5 text-sm font-medium text-ink transition-colors hover:border-line-strong hover:bg-panel-hi"
      aria-haspopup="menu"
      :aria-expanded="open"
      @click="open = !open"
    >
      <span class="h-2 w-2 rounded-[2px] bg-accent" aria-hidden="true" />
      <span class="max-w-[12rem] truncate">{{ label }}</span>
      <svg
        xmlns="http://www.w3.org/2000/svg"
        viewBox="0 0 24 24"
        fill="none"
        stroke="currentColor"
        stroke-width="1.75"
        stroke-linecap="round"
        stroke-linejoin="round"
        class="h-4 w-4 text-ink-subtle"
        aria-hidden="true"
      >
        <path d="m6 9 6 6 6-6" />
      </svg>
    </button>

    <template v-if="open">
      <button
        type="button"
        class="fixed inset-0 z-30 cursor-default"
        tabindex="-1"
        aria-hidden="true"
        @click="close"
      />
      <div
        class="absolute left-0 z-40 mt-1 w-64 overflow-hidden rounded-md border border-line bg-panel shadow-lg"
        role="menu"
      >
        <div class="max-h-72 overflow-auto p-1">
          <RouterLink
            v-for="portfolio in portfolios"
            :key="portfolio.id"
            :to="{ name: 'portfolio-dashboard', params: { id: portfolio.id } }"
            role="menuitem"
            class="flex items-center justify-between gap-2 rounded px-3 py-2 text-sm"
            :class="portfolio.id === activeId ? 'font-medium text-accent' : 'text-ink hover:bg-panel-hi'"
            @click="close"
          >
            <span class="truncate">{{ portfolio.name }}</span>
            <svg
              v-if="portfolio.id === activeId"
              xmlns="http://www.w3.org/2000/svg"
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              stroke-width="2"
              stroke-linecap="round"
              stroke-linejoin="round"
              class="h-4 w-4 shrink-0"
              aria-hidden="true"
            >
              <path d="M20 6 9 17l-5-5" />
            </svg>
          </RouterLink>
          <p v-if="portfolios.length === 0" class="px-3 py-2 text-sm text-ink-subtle">
            No portfolios yet
          </p>
        </div>
        <div class="border-t border-line p-1">
          <RouterLink
            :to="{ name: 'portfolios' }"
            role="menuitem"
            class="block rounded px-3 py-2 text-sm text-ink-muted hover:bg-panel-hi hover:text-ink"
            @click="close"
          >
            View all portfolios
          </RouterLink>
        </div>
      </div>
    </template>
  </div>
</template>
