<script setup lang="ts">
import PortfolioSparkline from './PortfolioSparkline.vue'
import type { Portfolio } from '@/types'

/**
 * A portfolio summary card. The body is a RouterLink to the dashboard (clicking
 * the card navigates); edit/delete are separate buttons rendered as siblings of
 * the link (never nested inside an <a>) and surface on hover/focus.
 */
defineProps<{
  portfolio: Portfolio
  benchmarkLabel: string
}>()

const emit = defineEmits<{
  edit: [portfolio: Portfolio]
  delete: [portfolio: Portfolio]
}>()
</script>

<template>
  <div
    class="group relative rounded-lg border border-line bg-panel transition-colors hover:border-line-strong"
  >
    <RouterLink
      :to="{ name: 'portfolio-dashboard', params: { id: portfolio.id } }"
      class="block rounded-lg p-4 outline-none focus-visible:ring-2 focus-visible:ring-accent-soft"
    >
      <h2 class="truncate pr-16 text-base font-semibold text-ink">{{ portfolio.name }}</h2>
      <p class="mt-0.5 truncate text-xs text-ink-subtle">{{ benchmarkLabel }}</p>
      <div class="mt-4">
        <PortfolioSparkline :portfolio-id="portfolio.id" />
      </div>
    </RouterLink>

    <div
      class="absolute right-2 top-2 flex gap-1 opacity-0 transition-opacity focus-within:opacity-100 group-hover:opacity-100"
    >
      <button
        type="button"
        class="grid h-8 w-8 place-items-center rounded-md text-ink-subtle transition-colors hover:bg-panel-hi hover:text-ink"
        :aria-label="`Edit ${portfolio.name}`"
        @click="emit('edit', portfolio)"
      >
        <svg
          xmlns="http://www.w3.org/2000/svg"
          viewBox="0 0 24 24"
          fill="none"
          stroke="currentColor"
          stroke-width="1.75"
          stroke-linecap="round"
          stroke-linejoin="round"
          class="h-4 w-4"
          aria-hidden="true"
        >
          <path d="M12 20h9" />
          <path d="M16.5 3.5a2.121 2.121 0 0 1 3 3L7 19l-4 1 1-4Z" />
        </svg>
      </button>
      <button
        type="button"
        class="grid h-8 w-8 place-items-center rounded-md text-ink-subtle transition-colors hover:bg-panel-hi hover:text-down"
        :aria-label="`Delete ${portfolio.name}`"
        @click="emit('delete', portfolio)"
      >
        <svg
          xmlns="http://www.w3.org/2000/svg"
          viewBox="0 0 24 24"
          fill="none"
          stroke="currentColor"
          stroke-width="1.75"
          stroke-linecap="round"
          stroke-linejoin="round"
          class="h-4 w-4"
          aria-hidden="true"
        >
          <path d="M3 6h18M8 6V4a1 1 0 0 1 1-1h6a1 1 0 0 1 1 1v2m2 0v14a1 1 0 0 1-1 1H6a1 1 0 0 1-1-1V6" />
          <path d="M10 11v6M14 11v6" />
        </svg>
      </button>
    </div>
  </div>
</template>
