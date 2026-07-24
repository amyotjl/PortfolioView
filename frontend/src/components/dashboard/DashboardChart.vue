<script setup lang="ts">
import { computed } from 'vue'
import { VChart } from '@/charts/echarts'
import { buildDashboardChartOption } from '@/charts/candles'
import { chartTheme } from '@/charts/theme'
import { useThemeStore } from '@/stores/theme'
import type { CandlesResponse } from '@/types'

/**
 * Presentation-only wrapper around the one linked-pane ECharts instance. All the
 * logic lives in the pure `buildDashboardChartOption`; this component just feeds
 * it the live payload, the flags, and the current theme tokens. The option
 * recomputes when the theme flips (chartTheme depends on the theme store), so
 * the chart re-renders in the new palette.
 */
const props = defineProps<{
  payload: CandlesResponse
  showBenchmark: boolean
}>()

const themeStore = useThemeStore()

const option = computed(() =>
  buildDashboardChartOption(props.payload, chartTheme(themeStore.theme), {
    showBenchmark: props.showBenchmark,
  }),
)
</script>

<template>
  <VChart class="h-[560px] w-full" :option="option" autoresize />
</template>
