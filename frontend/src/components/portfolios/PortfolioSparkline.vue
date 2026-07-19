<script setup lang="ts">
import { computed } from 'vue'
import Sparkline from '@/components/charts/Sparkline.vue'
import { usePortfolioCandlesQuery } from '@/composables/usePortfolioCandles'
import { formatCurrency } from '@/lib/format'

/**
 * Card trend block: latest portfolio value (exact, from the raw close string)
 * plus a close-value sparkline over the portfolio's available history. Owns its
 * own candles query so each card fetches independently and the cache dedupes.
 */
const props = defineProps<{ portfolioId: number }>()

const { closes, latestClose, status } = usePortfolioCandlesQuery(() => props.portfolioId)

const hasSeries = computed(() => closes.value.length >= 2)

const trend = computed<'up' | 'down' | 'flat'>(() => {
  if (!hasSeries.value) return 'flat'
  const first = closes.value[0]
  const last = closes.value[closes.value.length - 1]
  if (last > first) return 'up'
  if (last < first) return 'down'
  return 'flat'
})

const valueLabel = computed(() =>
  latestClose.value !== null ? formatCurrency(latestClose.value) : '—',
)

const ariaLabel = computed(() =>
  hasSeries.value
    ? `Portfolio value trend is ${trend.value} over the available history`
    : 'No value history yet',
)
</script>

<template>
  <div>
    <div v-if="status === 'pending'" class="space-y-2" aria-hidden="true">
      <div class="h-6 w-24 animate-pulse rounded bg-panel-hi" />
      <div class="h-10 animate-pulse rounded bg-panel-hi" />
    </div>
    <template v-else>
      <p class="numeric text-lg font-semibold text-ink">{{ valueLabel }}</p>
      <div class="mt-2">
        <Sparkline :values="closes" :trend="trend" :aria-label="ariaLabel">
          <template #empty>No activity yet</template>
        </Sparkline>
      </div>
    </template>
  </div>
</template>
