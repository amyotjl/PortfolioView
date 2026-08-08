<script setup lang="ts">
import { computed } from 'vue'
import ChartCard from './ChartCard.vue'
import AllocationDonut from './AllocationDonut.vue'
import AllocationTable from './AllocationTable.vue'
import SectorTreemap from './SectorTreemap.vue'
import SectorTreemapTable from './SectorTreemapTable.vue'
import { useAllocationsQuery } from '@/composables/useAllocations'
import { useSummaryQuery } from '@/composables/useSummary'
import { instrumentDonutRows, sectorDonutRows } from '@/charts/donuts'
import { allocationScopeNotice } from '@/lib/cash'
import { formatDate } from '@/lib/format'

/**
 * The two allocation donuts (by instrument, by sector) with their table twins.
 * Owns its own /allocations query (Pinia Colada dedupes), so the parent view
 * stays a thin composition surface. Allocation is an as-of-latest snapshot,
 * independent of the chart's date-range window.
 *
 * NO CASH SLICE (#80), deliberately. A slice would change every weight on screen
 * across four surfaces, the ordinal single-hue ramp cannot express "this slice is a
 * categorically different KIND of thing", and it would break the pinned invariant
 * that `by_instrument[].sector` is byte-identical to the matching `by_sector` label.
 * "How much is uninvested" is one number — a stat tile, not a slice.
 *
 * What a cash-tracked portfolio gets instead is a header sentence naming the scope,
 * because `/allocations`' `total_value` is holdings-only and is therefore LESS than
 * `/summary`'s `current_value` by exactly the cash balance. Saying so is cheaper than
 * leaving a reader to discover two totals that disagree. Copy lives in `lib/cash.ts`.
 */
const props = defineProps<{ portfolioId: number }>()

const { allocations, status } = useAllocationsQuery(() => props.portfolioId)
const { summary } = useSummaryQuery(() => props.portfolioId)

const scopeNotice = computed(() =>
  allocationScopeNotice({
    holdingsValue: summary.value?.holdings_value,
    currentValue: summary.value?.current_value,
    cashBalance: summary.value?.cash_balance,
  }),
)

const instrumentRows = computed(() =>
  allocations.value ? instrumentDonutRows(allocations.value) : [],
)
const sectorRows = computed(() => (allocations.value ? sectorDonutRows(allocations.value) : []))
const hasData = computed(() => instrumentRows.value.length > 0)
const asOfLabel = computed(() =>
  allocations.value?.as_of ? `as of ${formatDate(allocations.value.as_of)}` : '',
)
</script>

<template>
  <section aria-label="Allocation" class="space-y-3">
    <div class="flex items-baseline justify-between gap-2">
      <h2 class="text-sm font-semibold text-ink">Allocation</h2>
      <p v-if="asOfLabel" class="text-xs text-ink-subtle">{{ asOfLabel }}</p>
    </div>

    <!--
      `text-ink-muted`, not `text-ink-subtle`. Measured on the rendered page: subtle is
      #858d9c on #f4f6f9 = 3.12:1 light and #697386 on #0a0c11 = 4.10:1 dark, and at
      12px/400 this is normal text, so both fail AA's 4.5:1 (the large-text exception
      needs 18.66px at 600). Muted measures 5.81:1 and 7.62:1. This sentence is the one
      that explains why two totals on the same screen disagree — it is the last thing
      that should be hard to read. (The `asOfLabel` above keeps subtle: it is a
      redundant timestamp, not load-bearing prose, and changing it is not this issue.)
    -->
    <p v-if="scopeNotice" class="max-w-3xl text-xs text-ink-muted">{{ scopeNotice }}</p>

    <div v-if="status === 'pending'" class="grid gap-4 md:grid-cols-2">
      <div
        v-for="n in 2"
        :key="n"
        class="h-[392px] animate-pulse rounded-lg border border-line bg-panel"
        aria-hidden="true"
      />
      <span class="sr-only">Loading allocation…</span>
    </div>

    <div
      v-else-if="status === 'error'"
      class="rounded-lg border border-line bg-panel p-6 text-center text-sm text-ink-muted"
    >
      Allocation is unavailable right now.
    </div>

    <div
      v-else-if="!hasData"
      class="rounded-lg border border-dashed border-line-strong bg-panel p-6 text-center text-sm text-ink-muted"
    >
      No open holdings to break down yet.
    </div>

    <div v-else class="grid gap-4 md:grid-cols-2">
      <ChartCard title="By instrument">
        <template #chart>
          <AllocationDonut :rows="instrumentRows" name="By instrument" />
        </template>
        <template #table>
          <AllocationTable :rows="instrumentRows" />
        </template>
      </ChartCard>

      <ChartCard title="By sector">
        <template #chart>
          <AllocationDonut :rows="sectorRows" name="By sector" />
        </template>
        <template #table>
          <AllocationTable :rows="sectorRows" />
        </template>
      </ChartCard>

      <!--
        The treemap spans both columns: it needs the width to keep tiles square
        enough to hold their labels, and it is the only view showing which
        holdings sit inside which sector.
      -->
      <div class="md:col-span-2">
        <ChartCard title="Sector breakdown">
          <template #caption>
            <p>
              Tile area is market value; a sector's holdings are lighter shades of its
              color, matching the donut above.
            </p>
          </template>
          <template #chart>
            <SectorTreemap v-if="allocations" :allocations="allocations" />
          </template>
          <template #table>
            <SectorTreemapTable v-if="allocations" :allocations="allocations" />
          </template>
        </ChartCard>
      </div>
    </div>
  </section>
</template>
