<script setup lang="ts">
import { computed } from 'vue'
import { storeToRefs } from 'pinia'
import { useActivePortfolioStore } from '@/stores/active-portfolio'

/**
 * Placeholder switcher. It reflects the active-portfolio selection and links to
 * the portfolios list; the real name-labelled dropdown (backed by the portfolios
 * Pinia Colada query) arrives with the portfolios-list issue (#039).
 */
const { activeId } = storeToRefs(useActivePortfolioStore())

const label = computed(() =>
  activeId.value === null ? 'All portfolios' : `Portfolio #${activeId.value}`,
)
</script>

<template>
  <RouterLink
    :to="{ name: 'portfolios' }"
    class="inline-flex items-center gap-2 rounded-md border border-line bg-panel px-3 py-1.5 text-sm font-medium text-ink transition-colors hover:border-line-strong hover:bg-panel-hi"
  >
    <span class="h-2 w-2 rounded-[2px] bg-accent" aria-hidden="true" />
    <span>{{ label }}</span>
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
  </RouterLink>
</template>
