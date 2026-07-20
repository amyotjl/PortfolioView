<script setup lang="ts">
import { shallowRef, useSlots } from 'vue'

/**
 * Card shell for a chart plus its accessible "view as table" twin — every chart
 * card gets the toggle (dataviz: a table view always exists). Frequent toggles,
 * so both slots stay mounted (v-show) to avoid re-initialising ECharts. While
 * data refetches the body dims instead of flashing a skeleton ("refetch keeps
 * the frame").
 */
defineProps<{
  title: string
  refetching?: boolean
}>()

const slots = useSlots()
const view = shallowRef<'chart' | 'table'>('chart')
</script>

<template>
  <section class="rounded-lg border border-line bg-panel">
    <header class="flex items-center justify-between gap-3 border-b border-line px-4 py-3">
      <div class="min-w-0">
        <h2 class="text-sm font-semibold text-ink">{{ title }}</h2>
        <div v-if="slots.caption" class="mt-0.5 space-y-0.5 text-xs text-ink-subtle">
          <slot name="caption" />
        </div>
      </div>
      <div
        class="inline-flex shrink-0 rounded-md border border-line p-0.5"
        role="group"
        aria-label="View mode"
      >
        <button
          type="button"
          class="rounded px-2.5 py-1 text-xs font-medium transition-colors"
          :class="view === 'chart' ? 'bg-accent text-on-accent' : 'text-ink-muted hover:bg-panel-hi'"
          :aria-pressed="view === 'chart'"
          @click="view = 'chart'"
        >
          Chart
        </button>
        <button
          type="button"
          class="rounded px-2.5 py-1 text-xs font-medium transition-colors"
          :class="view === 'table' ? 'bg-accent text-on-accent' : 'text-ink-muted hover:bg-panel-hi'"
          :aria-pressed="view === 'table'"
          @click="view = 'table'"
        >
          Table
        </button>
      </div>
    </header>

    <div class="p-3 transition-opacity" :class="{ 'pointer-events-none opacity-60': refetching }">
      <div v-show="view === 'chart'"><slot name="chart" /></div>
      <div v-show="view === 'table'"><slot name="table" /></div>
    </div>
  </section>
</template>
