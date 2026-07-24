<script setup lang="ts">
import { computed } from 'vue'
import { formatCurrency, formatDate, formatPercent } from '@/lib/format'
import type { CandlesResponse } from '@/types'

/**
 * Accessible table twin of the linked chart — the WCAG-clean equivalent so no
 * value is reachable only by hovering. Rows are most-recent-first for scanning.
 * All figures reuse the decimal-string-safe formatters (no float coercion);
 * numeric columns are tabular-aligned.
 */
const props = defineProps<{
  payload: CandlesResponse
  showBenchmark: boolean
}>()

const EM_DASH = '—'

const showBenchmarkColumn = computed(() => props.showBenchmark && props.payload.benchmark !== null)

const rows = computed(() => {
  const benchmark = new Map((props.payload.benchmark?.values ?? []).map((p) => [p.t, p.v]))
  const flows = new Map(props.payload.flows.map((f) => [f.t, f.net]))
  const drawdown = new Map(props.payload.drawdown.map((p) => [p.t, p.v]))

  return [...props.payload.candles].reverse().map((c) => {
    const netStr = flows.get(c.t)
    const net = netStr === undefined ? null : Number(netStr)
    const benchStr = benchmark.get(c.t)
    const ddStr = drawdown.get(c.t)
    return {
      date: c.t,
      dateLabel: formatDate(c.t),
      close: formatCurrency(c.c),
      benchmark: benchStr === undefined ? EM_DASH : formatCurrency(benchStr),
      flow: netStr === undefined ? EM_DASH : `${net! > 0 ? '+' : ''}${formatCurrency(netStr)}`,
      flowColor: net === null || net === 0 ? 'text-ink-muted' : net > 0 ? 'text-up' : 'text-down',
      drawdown: ddStr === undefined ? EM_DASH : formatPercent(ddStr),
    }
  })
})
</script>

<template>
  <div class="max-h-[560px] overflow-auto">
    <table class="w-full text-sm">
      <caption class="sr-only">
        Portfolio close value, benchmark, net cash flow and drawdown by trading day
      </caption>
      <thead class="sticky top-0 bg-panel text-left text-xs text-ink-subtle">
        <tr class="border-b border-line">
          <th scope="col" class="px-3 py-2 font-medium">Date</th>
          <th scope="col" class="px-3 py-2 text-right font-medium">Close</th>
          <th v-if="showBenchmarkColumn" scope="col" class="px-3 py-2 text-right font-medium">
            Benchmark
          </th>
          <th scope="col" class="px-3 py-2 text-right font-medium">Net flow</th>
          <th scope="col" class="px-3 py-2 text-right font-medium">Drawdown</th>
        </tr>
      </thead>
      <tbody>
        <tr v-for="row in rows" :key="row.date" class="border-b border-line/60">
          <td class="px-3 py-1.5 text-ink-muted">{{ row.dateLabel }}</td>
          <td class="numeric px-3 py-1.5 text-right text-ink">{{ row.close }}</td>
          <td v-if="showBenchmarkColumn" class="numeric px-3 py-1.5 text-right text-ink-muted">
            {{ row.benchmark }}
          </td>
          <td class="numeric px-3 py-1.5 text-right" :class="row.flowColor">{{ row.flow }}</td>
          <td class="numeric px-3 py-1.5 text-right text-ink-muted">{{ row.drawdown }}</td>
        </tr>
      </tbody>
    </table>
  </div>
</template>
