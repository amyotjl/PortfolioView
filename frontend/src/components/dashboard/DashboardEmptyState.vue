<script setup lang="ts">
/**
 * Friendly empty dashboard, in two variants.
 *
 * `no-history` — the original: a portfolio with no priced days at all (zero
 * transactions, zero cash). An empty screen is an invitation to act, so it points
 * straight at adding the first transaction rather than rendering an empty chart.
 *
 * `cash-only` — new in #80, and a genuinely new state. A portfolio can now record a
 * real $10,000 deposit and own nothing: `/candles` returns a series (the deposit is
 * real history), but the candle legs are holdings-only and therefore all zero, so
 * there is still nothing to *chart*. Telling that reader "Nothing to chart yet — add
 * your first transaction" would be wrong twice: their money IS recorded, and the
 * thing missing is a holding, not a transaction.
 */
defineProps<{
  portfolioId: number
  variant?: 'no-history' | 'cash-only'
}>()
</script>

<template>
  <div class="rounded-lg border border-dashed border-line-strong bg-panel p-10 text-center">
    <template v-if="variant === 'cash-only'">
      <h2 class="text-base font-semibold text-ink">No holdings to chart yet</h2>
      <p class="mx-auto mt-1 max-w-md text-sm text-ink-muted">
        This portfolio’s cash is recorded — the tiles above already count it toward total
        value. Buy something to start building a value, benchmark and allocation history.
      </p>
    </template>
    <template v-else>
      <h2 class="text-base font-semibold text-ink">Nothing to chart yet</h2>
      <p class="mx-auto mt-1 max-w-sm text-sm text-ink-muted">
        Add your first transaction to see your portfolio value, cash flows, and allocation over
        time.
      </p>
    </template>

    <RouterLink
      :to="{ name: 'portfolio-transactions', params: { id: portfolioId } }"
      class="mt-5 inline-flex items-center gap-2 rounded-md bg-accent px-3.5 py-2 text-sm font-medium text-on-accent transition-colors hover:bg-accent-hi"
    >
      {{ variant === 'cash-only' ? 'Add a trade' : 'Add a transaction' }}
    </RouterLink>
  </div>
</template>
