import { computed, shallowRef, watch } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { useRangePresetStore, RANGE_PRESETS, type RangePreset } from '@/stores/range-preset'
import { presetToRange } from '@/lib/ranges'

/**
 * Dashboard view state that is mirrored to the URL query and restored from it:
 * the date-range preset (owned by useRangePresetStore) and the benchmark toggle.
 * Keeping it in the URL makes a dashboard view shareable and survives reload
 * (docs/PLAN.md § Dashboard). The candle *data* for the resulting window is
 * server state (a Pinia Colada query) — this composable only tracks selection.
 */
function firstQueryValue(value: unknown): string | undefined {
  const v = Array.isArray(value) ? value[0] : value
  return typeof v === 'string' ? v : undefined
}

function isPreset(value: string | undefined): value is RangePreset {
  return value !== undefined && (RANGE_PRESETS as readonly string[]).includes(value)
}

export function useDashboardParams() {
  const route = useRoute()
  const router = useRouter()
  const store = useRangePresetStore()
  const showBenchmark = shallowRef(false)

  function readFromUrl(): void {
    const range = firstQueryValue(route.query.range)
    if (isPreset(range)) store.setPreset(range)
    showBenchmark.value = firstQueryValue(route.query.benchmark) === 'true'
  }

  // Restore selection from the URL on entry (deep link / reload).
  readFromUrl()

  // Selection -> URL. `replace` so range flips don't pile up in history.
  // Guarded against redundant navigations, which also prevents a URL<->store loop.
  watch([() => store.preset, showBenchmark], ([preset, benchmark]) => {
    const nextBenchmark = benchmark ? 'true' : undefined
    if (route.query.range === preset && route.query.benchmark === nextBenchmark) return
    router.replace({ query: { ...route.query, range: preset, benchmark: nextBenchmark } })
  })

  // URL -> selection for back/forward, which change only the query and so do not
  // remount the view. Equality guards in both watchers keep this from looping.
  watch(
    () => [route.query.range, route.query.benchmark],
    () => readFromUrl(),
  )

  const preset = computed<RangePreset>(() => store.preset)
  const range = computed(() => presetToRange(store.preset))

  function setPreset(next: RangePreset): void {
    store.setPreset(next)
  }

  return { preset, setPreset, showBenchmark, range }
}
