<script setup lang="ts">
/**
 * Friendly empty dashboard for a portfolio with no priced days yet (zero
 * transactions). An empty screen is an invitation to act, so it points straight
 * at adding the first transaction rather than rendering an empty chart.
 */
defineProps<{ portfolioId: number }>()
</script>

<template>
  <div class="rounded-lg border border-dashed border-line-strong bg-panel p-10 text-center">
    <h2 class="text-base font-semibold text-ink">Nothing to chart yet</h2>
    <p class="mx-auto mt-1 max-w-sm text-sm text-ink-muted">
      Add your first transaction to see your portfolio value, cash flows, and allocation over time.
    </p>
    <RouterLink
      :to="{ name: 'portfolio-transactions', params: { id: portfolioId } }"
      class="mt-5 inline-flex items-center gap-2 rounded-md bg-accent px-3.5 py-2 text-sm font-medium text-on-accent transition-colors hover:bg-accent-hi"
    >
      Add a transaction
    </RouterLink>
  </div>
</template>
