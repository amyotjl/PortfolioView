<script setup lang="ts">
import SelectButton from 'primevue/selectbutton'
import ToggleSwitch from 'primevue/toggleswitch'
import { RANGE_PRESETS, type RangePreset } from '@/stores/range-preset'
import { selectButtonPt, toggleSwitchPt } from '@/primevue/pt'

/**
 * The dashboard's one filter row: date-range presets (segmented control) and a
 * benchmark on/off switch. Both are v-model contracts; the parent mirrors them
 * to the URL. Date range first, per the dataviz filter-composition rule.
 */
const preset = defineModel<RangePreset>('preset', { required: true })
const benchmark = defineModel<boolean>('benchmark', { required: true })

const presetOptions = RANGE_PRESETS.map((value) => ({ label: value, value }))
</script>

<template>
  <div class="flex flex-wrap items-center gap-x-6 gap-y-3">
    <SelectButton
      v-model="preset"
      :options="presetOptions"
      option-label="label"
      option-value="value"
      :allow-empty="false"
      :pt="selectButtonPt"
      aria-label="Date range"
    />
    <div class="flex items-center gap-2">
      <label for="benchmark-toggle" class="cursor-pointer text-sm text-ink-muted">
        Compare to benchmark
      </label>
      <ToggleSwitch
        v-model="benchmark"
        input-id="benchmark-toggle"
        aria-label="Compare to benchmark"
        :pt="toggleSwitchPt"
      />
    </div>
  </div>
</template>
