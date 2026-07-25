<script setup lang="ts">
import { computed } from 'vue'
import { VChart } from '@/charts/echarts'
import { buildAllocationDonutOption, type DonutRow } from '@/charts/donuts'
import { chartTheme } from '@/charts/theme'
import { useThemeStore } from '@/stores/theme'

/**
 * Presentation-only donut. The pure builder does the mapping + ordinal-ramp
 * coloring; this component supplies the rows, the series name, and the current
 * theme tokens (so it re-renders on a theme flip).
 */
const props = defineProps<{
  rows: DonutRow[]
  name: string
}>()

const themeStore = useThemeStore()

const option = computed(() =>
  buildAllocationDonutOption(props.rows, chartTheme(themeStore.theme), { name: props.name }),
)
</script>

<template>
  <!-- Height on the wrapper, not on <VChart> — see the note in DashboardChart.vue. -->
  <div class="h-[320px] w-full">
    <VChart :option="option" autoresize />
  </div>
</template>
