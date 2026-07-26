<script setup lang="ts">
import { computed } from 'vue'
import { deriveContributions, signedCents } from '@/charts/contributions'
import { centsToDecimalString } from '@/lib/money'
import { formatCurrency, formatDate } from '@/lib/format'
import type { CandlesResponse } from '@/types'

/**
 * Accessible table twin of the contribution-vs-growth area — the WCAG-clean
 * equivalent, so no figure is reachable only by hovering, and the exact growth
 * sign is available as text rather than as a band color. Rows are
 * most-recent-first for scanning, matching DashboardChartTable.
 *
 * Every figure comes from the same pure derivation the chart uses (exact cents),
 * formatted through the decimal-string-safe formatters.
 */
const props = defineProps<{ payload: CandlesResponse }>()

const rows = computed(() =>
  [...deriveContributions(props.payload).points].reverse().map((p) => ({
    date: p.t,
    dateLabel: formatDate(p.t),
    value: formatCurrency(centsToDecimalString(p.valueCents)),
    contributed: formatCurrency(centsToDecimalString(p.contributedCents)),
    growth: signedCents(p.growthCents),
    growthColor:
      p.growthCents === 0 ? 'text-ink-muted' : p.growthCents > 0 ? 'text-up' : 'text-down',
  })),
)
</script>

<template>
  <div class="max-h-[360px] overflow-auto">
    <table class="w-full text-sm">
      <caption class="sr-only">
        Total value, contributed capital and growth by trading day
      </caption>
      <thead class="sticky top-0 bg-panel text-left text-xs text-ink-subtle">
        <tr class="border-b border-line">
          <th scope="col" class="px-3 py-2 font-medium">Date</th>
          <th scope="col" class="px-3 py-2 text-right font-medium">Total value</th>
          <th scope="col" class="px-3 py-2 text-right font-medium">Contributed capital</th>
          <th scope="col" class="px-3 py-2 text-right font-medium">Growth</th>
        </tr>
      </thead>
      <tbody>
        <tr v-for="row in rows" :key="row.date" class="border-b border-line/60">
          <td class="px-3 py-1.5 text-ink-muted">{{ row.dateLabel }}</td>
          <td class="numeric px-3 py-1.5 text-right text-ink">{{ row.value }}</td>
          <td class="numeric px-3 py-1.5 text-right text-ink-muted">{{ row.contributed }}</td>
          <td class="numeric px-3 py-1.5 text-right" :class="row.growthColor">{{ row.growth }}</td>
        </tr>
      </tbody>
    </table>
  </div>
</template>
