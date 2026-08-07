<script setup lang="ts">
import { computed } from 'vue'
import StatTile from './StatTile.vue'
import {
  buildSummaryTiles,
  depositBasisAdvisory,
  tracksCash,
  SKELETON_TILE_COUNT,
} from '@/lib/summaryTiles'
import { formatDate } from '@/lib/format'
import type { Summary } from '@/types'

/**
 * The lifetime stat-tile row, fed from /summary ONLY (never derived from a
 * windowed candles payload). Shows skeletons while the summary loads and an
 * "as of" caption for the priced-through date.
 *
 * EIGHT TILES OR SIX (#80), decided by `cash_balance !== null`. The grid follows:
 * 2×4 when cash is tracked, 2×3 when it isn't. Six tiles in the old
 * `xl:grid-cols-6` was already the cramped case — `text-lg` money at ~150px wraps —
 * so 2×3 is an improvement independent of cash.
 *
 * The skeleton count comes from `SKELETON_TILE_COUNT`, which is derived from the
 * builder rather than hardcoded. The basis is unknown while /summary is in flight,
 * so a cash-tracked portfolio reflows once; persisting "tracks cash" client-side
 * would mean inventing client state for server data.
 */
const props = defineProps<{
  summary: Summary | null
  loading: boolean
  asOf: string | null
}>()

const tiles = computed(() => buildSummaryTiles(props.summary))
const asOfLabel = computed(() => (props.asOf ? `as of ${formatDate(props.asOf)}` : 'No priced days yet'))

/** 2×4 with cash, 2×3 without. */
const gridClass = computed(() =>
  tracksCash(props.summary)
    ? 'grid gap-3 sm:grid-cols-2 lg:grid-cols-4'
    : 'grid gap-3 sm:grid-cols-2 lg:grid-cols-3',
)

/**
 * The invitation to record deposits — shown only on the trade basis, and only for a
 * portfolio that actually has history to reinterpret. Small print, not a dismissable
 * banner (that would need client state and a persistence decision).
 */
const basisAdvisory = computed(() => depositBasisAdvisory(props.summary))
</script>

<template>
  <section aria-label="Lifetime performance">
    <div class="mb-3 flex items-baseline justify-between gap-2">
      <h2 class="text-sm font-semibold text-ink">Lifetime performance</h2>
      <p class="text-xs text-ink-subtle">{{ asOfLabel }}</p>
    </div>

    <p v-if="basisAdvisory" class="mb-3 max-w-3xl text-xs text-ink-subtle">
      {{ basisAdvisory }}
    </p>

    <div v-if="loading" class="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
      <div
        v-for="n in SKELETON_TILE_COUNT"
        :key="n"
        class="h-[92px] animate-pulse rounded-lg border border-line bg-panel"
        aria-hidden="true"
      />
      <span class="sr-only">Loading performance summary…</span>
    </div>

    <div v-else :class="gridClass">
      <StatTile v-for="tile in tiles" :key="tile.key" :tile="tile" />
    </div>
  </section>
</template>
