<script setup lang="ts">
import { computed } from 'vue'
import StatTile from './StatTile.vue'
import { buildSummaryTiles } from '@/lib/summaryTiles'
import { formatDate } from '@/lib/format'
import type { Summary } from '@/types'

/**
 * The lifetime stat-tile row, fed from /summary ONLY (never derived from a
 * windowed candles payload). Shows skeletons while the summary loads and an
 * "as of" caption for the priced-through date.
 */
const props = defineProps<{
  summary: Summary | null
  loading: boolean
  asOf: string | null
}>()

const tiles = computed(() => buildSummaryTiles(props.summary))
const asOfLabel = computed(() => (props.asOf ? `as of ${formatDate(props.asOf)}` : 'No priced days yet'))
</script>

<template>
  <section aria-label="Lifetime performance">
    <div class="mb-3 flex items-baseline justify-between gap-2">
      <h2 class="text-sm font-semibold text-ink">Lifetime performance</h2>
      <p class="text-xs text-ink-subtle">{{ asOfLabel }}</p>
    </div>

    <div v-if="loading" class="grid gap-3 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-6">
      <div
        v-for="n in 6"
        :key="n"
        class="h-[92px] animate-pulse rounded-lg border border-line bg-panel"
        aria-hidden="true"
      />
      <span class="sr-only">Loading performance summary…</span>
    </div>

    <div v-else class="grid gap-3 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-6">
      <StatTile v-for="tile in tiles" :key="tile.key" :tile="tile" />
    </div>
  </section>
</template>
