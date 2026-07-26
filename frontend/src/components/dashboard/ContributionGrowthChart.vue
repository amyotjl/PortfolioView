<script setup lang="ts">
import { computed } from 'vue'
import { VChart } from '@/charts/echarts'
import { buildContributionGrowthOption, deriveContributions } from '@/charts/contributions'
import { chartTheme } from '@/charts/theme'
import { useThemeStore } from '@/stores/theme'
import type { CandlesResponse } from '@/types'

/**
 * Presentation-only wrapper for the contribution-vs-growth stacked area (#52).
 * The derivation and the option are both pure (charts/contributions.ts); this
 * component only feeds them the live payload and the current theme tokens, so the
 * chart re-renders on a theme flip.
 */
const props = defineProps<{ payload: CandlesResponse }>()

const themeStore = useThemeStore()

const contributions = computed(() => deriveContributions(props.payload))
const option = computed(() =>
  buildContributionGrowthOption(contributions.value, chartTheme(themeStore.theme)),
)
</script>

<template>
  <!-- Height on the WRAPPER, never on <VChart> — see the note in DashboardChart.vue. -->
  <div class="h-[360px] w-full">
    <VChart :option="option" autoresize />
  </div>
</template>
