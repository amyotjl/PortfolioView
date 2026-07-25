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
  <!--
    THE HEIGHT MUST LIVE ON THIS WRAPPER, not on <VChart>.
    vue-echarts renders a custom element and injects an UNLAYERED rule into
    <head>: `x-vue-echarts { display:block; width:100%; height:100%; min-width:0 }`.
    Unlayered CSS outranks anything in `@layer utilities`, which is where Tailwind
    puts its utilities — so `class="h-[560px]"` on the component is silently
    overridden by `height: 100%`, resolves against an auto-height parent, and the
    chart collapses to 0px with no error anywhere. Sizing the parent instead gives
    that 100% a definite height to resolve against.
    Found by the e2e smoke suite (#51), which asserts a painted height precisely so
    this cannot regress — a unit test cannot see it, since it is real layout.
  -->
  <div class="h-[560px] w-full">
    <VChart :option="option" autoresize />
  </div>
</template>
