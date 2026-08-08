<script setup lang="ts">
import { computed } from 'vue'
import Button from 'primevue/button'
import { usePortfolioCandlesQuery } from '@/composables/usePortfolioCandles'
import { useSummaryQuery } from '@/composables/useSummary'
import { useDashboardParams } from '@/composables/useDashboardParams'
import { negativeCashNotice } from '@/lib/cash'
import { toCents } from '@/lib/money'
import { mapApiError } from '@/lib/formErrors'
import { buttonPt } from '@/primevue/pt'
import AdvisoryNotice from '@/components/ui/AdvisoryNotice.vue'
import RangeControls from '@/components/dashboard/RangeControls.vue'
import StatTileRow from '@/components/dashboard/StatTileRow.vue'
import ChartCard from '@/components/dashboard/ChartCard.vue'
import DashboardChart from '@/components/dashboard/DashboardChart.vue'
import DashboardChartTable from '@/components/dashboard/DashboardChartTable.vue'
import DashboardEmptyState from '@/components/dashboard/DashboardEmptyState.vue'
import ContributionGrowthChart from '@/components/dashboard/ContributionGrowthChart.vue'
import ContributionGrowthTable from '@/components/dashboard/ContributionGrowthTable.vue'
import AllocationSection from '@/components/dashboard/AllocationSection.vue'

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

/** True iff the portfolio records cash — read from the payload, never from /summary. */
const tracksCash = computed(() => payload.value?.cash !== null && payload.value?.cash !== undefined)

/**
 * Holdings-only candles that are all zero. Compared in exact integer cents, not with
 * `Number(c.c) !== 0`.
 */
const hasHoldingsToChart = computed(
  () => payload.value?.candles.some((c) => (toCents(c.c) ?? 0) !== 0) ?? false,
)

/**
 * THE EMPTY PREDICATE, WIDENED (#80) — and widened only for cash-tracked portfolios,
 * so an untracked one behaves exactly as before.
 *
 * `candles.length === 0` alone is no longer sufficient: a portfolio with a real
 * deposit and no trades now returns a full series whose candle legs are all zero
 * (candles are holdings-only). Rendering that would paint a flat line at $0.00 and a
 * benchmark comparison against nothing.
 */
const isEmpty = computed(() => {
  if (candles.status.value !== 'success') return false
  if ((payload.value?.candles.length ?? 0) === 0) return true
  return tracksCash.value && !hasHoldingsToChart.value
})

/** Which empty-state copy to show — "your cash is recorded" vs "nothing here yet". */
const emptyVariant = computed<'no-history' | 'cash-only'>(() =>
  tracksCash.value && (payload.value?.cash?.some((p) => (toCents(p.v) ?? 0) !== 0) ?? false)
    ? 'cash-only'
    : 'no-history',
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

/**
 * Negative-cash advisory, below the tile row.
 *
 * Driven by /summary rather than by the windowed candles payload on purpose: the tiles
 * it sits under are lifetime figures, and a range change must not make a screen-reader
 * re-announce a fact that has not changed.
 */
const cashNotice = computed(() => negativeCashNotice(summaryData.value?.cash_balance ?? null))

/**
 * The chart card's caption. On the cash basis it has to state the relationship between
 * the panes once, because the candlestick is now holdings-only while the tiles above
 * report a total that includes cash — and because a trade no longer appears in the
 * flow pane at all.
 */
const chartCaption = computed(() =>
  tracksCash.value
    ? 'Candlesticks are holdings value; hover any day for total value, holdings and cash. The lower pane shows deposits & withdrawals only — under a cash account a trade moves money between cash and holdings without changing your total.'
    : 'Candlesticks are portfolio value; the accent line is the cash-flow-matched benchmark.',
)

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

    <!--
      Empty portfolio. The tile row is rendered above it in the cash-only variant:
      the reader's deposit IS on screen as Total value / Cash, which is precisely
      what makes "no holdings to chart" an honest thing to say next to it.
    -->
    <template v-else-if="isEmpty">
      <template v-if="emptyVariant === 'cash-only'">
        <StatTileRow :summary="summaryData" :loading="summaryLoading" :as-of="asOf" />
        <AdvisoryNotice :message="cashNotice" tone="warn" />
      </template>
      <DashboardEmptyState :portfolio-id="portfolioId" :variant="emptyVariant" />
    </template>

    <!-- Loaded -->
    <template v-else-if="payload">
      <StatTileRow :summary="summaryData" :loading="summaryLoading" :as-of="asOf" />
      <AdvisoryNotice :message="cashNotice" tone="warn" />

      <ChartCard title="Value, cash flow & drawdown" :refetching="isRefetching">
        <template #caption>
          <p v-for="(note, i) in notices" :key="i">{{ note }}</p>
          <!--
            On the cash basis the caption is shown even alongside a meta notice: it
            explains what the two panes now mean, which a reader needs regardless of
            whether some days were forward-filled.
          -->
          <p v-if="tracksCash || notices.length === 0">{{ chartCaption }}</p>
        </template>
        <template #chart>
          <DashboardChart :payload="payload" :show-benchmark="showBenchmark" />
        </template>
        <template #table>
          <DashboardChartTable :payload="payload" :show-benchmark="showBenchmark" />
        </template>
      </ChartCard>

      <ChartCard title="Contributed capital vs growth" :refetching="isRefetching">
        <template #caption>
          <p>
            Contributed capital starts at this range’s opening value and adds every net cash
            flow since, so growth is the change in value that cash flows don’t explain —
            reinvested dividends count as growth, not as a contribution.
          </p>
          <p>
            When the portfolio sits below its contributions, the shortfall is the band above
            the value line.
          </p>
          <p v-if="tracksCash">
            Total value here includes your cash, so buying something moves money between cash
            and holdings without changing the line.
          </p>
        </template>
        <template #chart>
          <ContributionGrowthChart :payload="payload" />
        </template>
        <template #table>
          <ContributionGrowthTable :payload="payload" />
        </template>
      </ChartCard>

      <AllocationSection :portfolio-id="portfolioId" />
    </template>
  </section>
</template>
