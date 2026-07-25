<script setup lang="ts">
import { computed } from 'vue'
import { VChart } from '@/charts/echarts'
import { buildSectorTreemapOption, sectorTreemapNodes } from '@/charts/treemap'
import { chartTheme } from '@/charts/theme'
import { useThemeStore } from '@/stores/theme'
import type { Allocations } from '@/types'

/**
 * Presentation-only sector treemap (#53). The hierarchy build and the option are
 * both pure (charts/treemap.ts); this component supplies the payload and the
 * current theme tokens, so it re-renders in the new palette on a theme flip —
 * which matters more here than elsewhere, since tile label inks are chosen for
 * contrast against the resolved fills.
 */
const props = defineProps<{ allocations: Allocations }>()

const themeStore = useThemeStore()

const option = computed(() => {
  const theme = chartTheme(themeStore.theme)
  return buildSectorTreemapOption(sectorTreemapNodes(props.allocations, theme), theme)
})
</script>

<template>
  <!-- Height on the WRAPPER, never on <VChart> — see the note in DashboardChart.vue. -->
  <div class="h-[420px] w-full">
    <VChart :option="option" autoresize />
  </div>
</template>
