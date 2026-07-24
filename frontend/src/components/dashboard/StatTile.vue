<script setup lang="ts">
import { computed } from 'vue'
import type { SummaryTile } from '@/lib/summaryTiles'

/**
 * One stat tile (presentation only). The view model — including em-dash null
 * handling and the directional sign — comes from the pure `buildSummaryTiles`
 * mapper; this component just renders it. `.numeric` gives the ledger look
 * (mono + tabular figures) used across the app for money.
 */
const props = defineProps<{ tile: SummaryTile }>()

const valueColor = computed(() =>
  props.tile.sign === 'up' ? 'text-up' : props.tile.sign === 'down' ? 'text-down' : 'text-ink',
)
</script>

<template>
  <div class="rounded-lg border border-line bg-panel p-4">
    <p class="text-xs font-medium uppercase tracking-wide text-ink-subtle">{{ tile.label }}</p>
    <p class="numeric mt-1 font-semibold" :class="[valueColor, tile.hero ? 'text-2xl' : 'text-lg']">
      {{ tile.value }}
    </p>
    <p v-if="tile.sub" class="numeric mt-0.5 text-sm" :class="valueColor">{{ tile.sub }}</p>
    <p v-if="tile.hint" class="mt-1 text-xs text-ink-subtle">{{ tile.hint }}</p>
  </div>
</template>
