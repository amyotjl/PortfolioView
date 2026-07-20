<script setup lang="ts">
import { computed } from 'vue'
import Button from 'primevue/button'
import { usePortfolioCandlesQuery } from '@/composables/usePortfolioCandles'
import { useSummaryQuery } from '@/composables/useSummary'
import { useDashboardParams } from '@/composables/useDashboardParams'
import { mapApiError } from '@/lib/formErrors'
import { buttonPt } from '@/primevue/pt'
import RangeControls from '@/components/dashboard/RangeControls.vue'
import StatTileRow from '@/components/dashboard/StatTileRow.vue'
import ChartCard from '@/components/dashboard/ChartCard.vue'
import DashboardChart from '@/components/dashboard/DashboardChart.vue'
import DashboardChartTable from '@/components/dashboard/DashboardChartTable.vue'
import DashboardEmptyState from '@/components/dashboard/DashboardEmptyState.vue'

/**
 * The dashboard route — a thin composition surface. Server state comes from
 * Pinia Colada queries (candles keyed by portfolio/range/benchmark; summary
 * keyed by portfolio); the range preset and benchmark toggle are mirrored to the
 * URL by useDashboardParams. All chart building is delegated to pure builders.
 */
const props = defineProps<{ id: string }>()
const portfolioId = computed(() => Number(props.id))

const { preset, setPreset, showBenchmark, range } = useDashboardParams()

const candles = usePortfolioCandlesQuery(portfolioId, range, { benchmark: showBenchmark })
const summaryQuery = useSummaryQuery(portfolioId)

const payload = computed(() => candles.data.value ?? null)
const isInitialLoading = computed(() => candles.status.value === 'pending')
const isError = computed(() => candles.status.value === 'error')
const isEmpty = computed(
  () => candles.status.value === 'success' && (payload.value?.candles.length ?? 0) === 0,
)
const isRefetching = computed(
  () => candles.asyncStatus.value === 'loading' && payload.value !== null,
)
const errorMessage = computed(
  () => mapApiError(candles.error.value, []).formMessage ?? 'We couldn’t load this dashboard.',
)

const summaryData = summaryQuery.summary
const summaryLoading = computed(() => summaryQuery.status.value === 'pending')
const asOf = computed(() => summaryData.value?.as_of ?? null)

/** Honest surfacing of the payload's meta flags (docs/PLAN.md § Dashboard). */
const notices = computed<string[]>(() => {
  const meta = payload.value?.meta
  if (!meta) return []
  const out: string[] = []
  if (meta.partial) {
    out.push('Data is still backfilling — the most recent days may be incomplete.')
  }
  if (meta.filled_dates.length > 0) {
    const n = meta.filled_dates.length
    out.push(`${n} trading day${n === 1 ? '' : 's'} forward-filled from the prior close.`)
  }
  if (showBenchmark.value && meta.benchmark_clamped) {
    out.push('Benchmark start clamped to its available history.')
  }
  return out
})

function retry(): void {
  candles.refetch()
}
</script>

<template>
  <section class="space-y-5">
    <header class="flex flex-wrap items-center justify-between gap-3">
      <h1 class="text-xl font-semibold tracking-tight text-ink">Dashboard</h1>
      <RangeControls
        :preset="preset"
        v-model:benchmark="showBenchmark"
        @update:preset="setPreset"
      />
    </header>

    <!-- Error (envelope-mapped) -->
    <div v-if="isError" class="rounded-lg border border-line bg-panel p-8 text-center">
      <p class="text-sm text-ink">{{ errorMessage }}</p>
      <p class="mt-1 text-sm text-ink-muted">Check your connection and try again.</p>
      <Button label="Retry" severity="secondary" class="mt-4" :pt="buttonPt" @click="retry" />
    </div>

    <!-- Initial load -->
    <template v-else-if="isInitialLoading">
      <StatTileRow :summary="null" :loading="true" :as-of="null" />
      <div
        class="h-[608px] animate-pulse rounded-lg border border-line bg-panel"
        aria-hidden="true"
      />
      <span class="sr-only">Loading dashboard…</span>
    </template>

    <!-- Empty portfolio -->
    <DashboardEmptyState v-else-if="isEmpty" :portfolio-id="portfolioId" />

    <!-- Loaded -->
    <template v-else-if="payload">
      <StatTileRow :summary="summaryData" :loading="summaryLoading" :as-of="asOf" />

      <ChartCard title="Value, cash flow & drawdown" :refetching="isRefetching">
        <template #caption>
          <p v-for="(note, i) in notices" :key="i">{{ note }}</p>
          <p v-if="notices.length === 0">
            Candlesticks are portfolio value; the accent line is the cash-flow-matched benchmark.
          </p>
        </template>
        <template #chart>
          <DashboardChart :payload="payload" :show-benchmark="showBenchmark" />
        </template>
        <template #table>
          <DashboardChartTable :payload="payload" :show-benchmark="showBenchmark" />
        </template>
      </ChartCard>
    </template>
  </section>
</template>
