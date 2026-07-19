import { shallowRef } from 'vue'
import { defineStore } from 'pinia'

/** Dashboard date-range presets (mirrored to the URL by the dashboard in M6). */
export const RANGE_PRESETS = ['1M', '3M', '6M', 'YTD', '1Y', '5Y', 'ALL'] as const
export type RangePreset = (typeof RANGE_PRESETS)[number]

/**
 * Client-owned view preference: which date-range preset the dashboard shows.
 * The candle data for a range is server state (a Pinia Colada query keyed by
 * portfolio + from/to); this store only remembers the selection.
 */
export const useRangePresetStore = defineStore('rangePreset', () => {
  const preset = shallowRef<RangePreset>('1Y')

  function setPreset(next: RangePreset): void {
    preset.value = next
  }

  return { preset, setPreset }
})
