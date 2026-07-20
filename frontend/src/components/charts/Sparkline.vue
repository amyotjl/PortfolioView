<script setup lang="ts">
import { computed } from 'vue'
import { buildSparkline } from '@/lib/sparkline'

/**
 * Presentation-only sparkline: geometry comes from the pure `buildSparkline`
 * helper, colour from the caller-supplied period `trend` (gain-green / loss-red
 * are the data tokens). The svg stretches to its container width with a
 * non-scaling stroke; `aria-label` carries the trend for assistive tech so the
 * meaning is never colour-alone.
 */
const props = withDefaults(
  defineProps<{
    values: number[]
    trend?: 'up' | 'down' | 'flat'
    height?: number
    ariaLabel?: string
  }>(),
  { trend: 'flat', height: 40 },
)

const VIEW_WIDTH = 240

const geometry = computed(() =>
  buildSparkline(props.values, { width: VIEW_WIDTH, height: props.height }),
)

const colorClass = computed(() =>
  props.trend === 'up' ? 'text-up' : props.trend === 'down' ? 'text-down' : 'text-ink-subtle',
)
</script>

<template>
  <svg
    v-if="geometry"
    :viewBox="`0 0 ${geometry.width} ${geometry.height}`"
    :style="{ height: `${geometry.height}px` }"
    class="block w-full"
    :class="colorClass"
    preserveAspectRatio="none"
    role="img"
    :aria-label="ariaLabel"
  >
    <path :d="geometry.area" fill="currentColor" fill-opacity="0.1" />
    <path
      :d="geometry.line"
      fill="none"
      stroke="currentColor"
      stroke-width="1.5"
      stroke-linecap="round"
      stroke-linejoin="round"
      vector-effect="non-scaling-stroke"
    />
  </svg>
  <div v-else class="flex items-center text-xs text-ink-subtle" :style="{ height: `${height}px` }">
    <slot name="empty">No data yet</slot>
  </div>
</template>
