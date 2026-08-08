<script setup lang="ts">
import { computed } from 'vue'
import { centsToDecimalString, toCents } from '@/lib/money'
import { formatCurrency, formatDate, formatPercent } from '@/lib/format'
import type { CandlesResponse } from '@/types'

/**
 * Accessible table twin of the linked chart — the WCAG-clean equivalent so no
 * value is reachable only by hovering. Rows are most-recent-first for scanning.
 * All figures reuse the decimal-string-safe formatters (no float coercion);
 * numeric columns are tabular-aligned.
 *
 * CASH (#80): two extra columns appear when the portfolio tracks cash, mirroring the
 * two extra tooltip rows on the chart — `Cash` (the day's end-of-day balance) and
 * `Total` (holdings + cash). They are conditional on `payload.cash !== null` for the
 * same reason the chart is: the payload being rendered is the only discriminator that
 * cannot disagree with itself. Totals are summed in exact integer cents.
 *
 * Cash is NOT colored by sign. up/down are reserved for real gain/loss polarity and a
 * negative balance is a bookkeeping gap, not a loss — and `text-warn` fails 4.5:1 for
 * table text anyway, so a negative balance is carried by its minus sign alone.
 */
const props = defineProps<{
  payload: CandlesResponse
  showBenchmark: boolean
}>()

const EM_DASH = '—'

const showBenchmarkColumn = computed(() => props.showBenchmark && props.payload.benchmark !== null)
const showCashColumns = computed(() => props.payload.cash !== null)

const caption = computed(() =>
  showCashColumns.value
    ? 'Total value, holdings close, cash balance, benchmark, deposits and withdrawals, and drawdown by trading day'
    : 'Portfolio close value, benchmark, net cash flow and drawdown by trading day',
)

const rows = computed(() => {
  const benchmark = new Map((props.payload.benchmark?.values ?? []).map((p) => [p.t, p.v]))
  const flows = new Map(props.payload.flows.map((f) => [f.t, f.net]))
  const drawdown = new Map(props.payload.drawdown.map((p) => [p.t, p.v]))
  const cash = new Map((props.payload.cash ?? []).map((p) => [p.t, p.v]))

  return [...props.payload.candles].reverse().map((c) => {
    const netStr = flows.get(c.t)
    const net = netStr === undefined ? null : Number(netStr)
    const benchStr = benchmark.get(c.t)
    const ddStr = drawdown.get(c.t)

    // Cash defaults to 0 for a swept day the series doesn't cover (it is
    // end-of-day, so an absent point means no movement had happened yet).
    const cashCents = toCents(cash.get(c.t) ?? '0') ?? 0
    const holdingsCents = toCents(c.c)
    const totalCents = holdingsCents === null ? null : holdingsCents + cashCents

    return {
      date: c.t,
      dateLabel: formatDate(c.t),
      close: formatCurrency(c.c),
      cash: formatCurrency(centsToDecimalString(cashCents)),
      total: totalCents === null ? EM_DASH : formatCurrency(centsToDecimalString(totalCents)),
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
        {{ caption }}
      </caption>
      <thead class="sticky top-0 bg-panel text-left text-xs text-ink-subtle">
        <tr class="border-b border-line">
          <th scope="col" class="px-3 py-2 font-medium">Date</th>
          <th v-if="showCashColumns" scope="col" class="px-3 py-2 text-right font-medium">Total</th>
          <th scope="col" class="px-3 py-2 text-right font-medium">
            {{ showCashColumns ? 'Holdings' : 'Close' }}
          </th>
          <th v-if="showCashColumns" scope="col" class="px-3 py-2 text-right font-medium">Cash</th>
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
          <td v-if="showCashColumns" class="numeric px-3 py-1.5 text-right font-medium text-ink">
            {{ row.total }}
          </td>
          <td class="numeric px-3 py-1.5 text-right text-ink">{{ row.close }}</td>
          <td v-if="showCashColumns" class="numeric px-3 py-1.5 text-right text-ink-muted">
            {{ row.cash }}
          </td>
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
