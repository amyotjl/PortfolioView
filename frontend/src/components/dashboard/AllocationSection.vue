<script setup lang="ts">
import { computed } from 'vue'
import ChartCard from './ChartCard.vue'
import AllocationDonut from './AllocationDonut.vue'
import AllocationTable from './AllocationTable.vue'
import { useAllocationsQuery } from '@/composables/useAllocations'
import { instrumentDonutRows, sectorDonutRows } from '@/charts/donuts'
import { formatDate } from '@/lib/format'

/**
 * The two allocation donuts (by instrument, by sector) with their table twins.
 * Owns its own /allocations query (Pinia Colada dedupes), so the parent view
 * stays a thin composition surface. Allocation is an as-of-latest snapshot,
 * independent of the chart's date-range window.
 */
const props = defineProps<{ portfolioId: number }>()

const { allocations, status } = useAllocationsQuery(() => props.portfolioId)

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
    </div>
  </section>
</template>
