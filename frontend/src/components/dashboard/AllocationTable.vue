<script setup lang="ts">
import { computed } from 'vue'
import { formatCurrency, formatPercent } from '@/lib/format'
import type { DonutRow } from '@/charts/donuts'

/**
 * Accessible table twin of an allocation donut — exact value and weight for
 * every slice (including small ones whose donut labels are hidden). Rows arrive
 * largest-first from the server.
 */
const props = defineProps<{ rows: DonutRow[] }>()

const formattedRows = computed(() =>
  props.rows.map((r) => ({
    name: r.name,
    value: formatCurrency(r.valueStr),
    weight: formatPercent(r.weightStr),
  })),
)
</script>

<template>
  <div class="max-h-[320px] overflow-auto">
    <table class="w-full text-sm">
      <caption class="sr-only">Allocation value and weight by holding</caption>
      <thead class="sticky top-0 bg-panel text-left text-xs text-ink-subtle">
        <tr class="border-b border-line">
          <th scope="col" class="px-3 py-2 font-medium">Name</th>
          <th scope="col" class="px-3 py-2 text-right font-medium">Value</th>
          <th scope="col" class="px-3 py-2 text-right font-medium">Weight</th>
        </tr>
      </thead>
      <tbody>
        <tr v-for="row in formattedRows" :key="row.name" class="border-b border-line/60">
          <td class="px-3 py-1.5 text-ink">{{ row.name }}</td>
          <td class="numeric px-3 py-1.5 text-right text-ink-muted">{{ row.value }}</td>
          <td class="numeric px-3 py-1.5 text-right text-ink">{{ row.weight }}</td>
        </tr>
      </tbody>
    </table>
  </div>
</template>
