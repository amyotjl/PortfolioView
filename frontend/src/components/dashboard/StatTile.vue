<script setup lang="ts">
import { computed } from 'vue'
import type { SummaryTile } from '@/lib/summaryTiles'

/**
 * One stat tile (presentation only). The view model — including em-dash null
 * handling and the directional sign — comes from the pure `buildSummaryTiles`
 * mapper; this component just renders it. `.numeric` gives the ledger look
 * (mono + tabular figures) used across the app for money.
 *
 * FOUR SIGNS, AND `warn` IS NOT `down` (#80). up/down are reserved app-wide for
 * real gain/loss polarity, so negative cash — which is a bookkeeping gap, not a
 * loss — wears `warn` instead.
 *
 * CONTRAST, AND THE ONE PLACE #80's DESIGN WAS MEASURABLY WRONG.
 * `text-warn` is 3.68:1 on the panel in both themes (measured: #b5790a on #ffffff),
 * which FAILS the 4.5:1 requirement for normal text and passes only the 3:1 large-text
 * exception. The issue assumed `text-lg font-semibold` already qualified — it does not:
 * WCAG's bold threshold is 14pt = **18.66px**, and `text-lg` is 18px, so the Cash tile's
 * value sat 0.66px under the line at 13.5pt bold. Verified with `getComputedStyle`, not
 * from a screenshot.
 *
 * So the non-hero value is `text-xl` (20px = 15pt bold), which clears the threshold with
 * room to spare. Applied to EVERY tile rather than only the warn one: a single tile in a
 * larger size than its siblings reads as a rendering bug, and the 2×3/2×4 grid this
 * replaced `xl:grid-cols-6` with gives each tile enough width that 20px money does not
 * wrap (the wrap at ~150px is exactly why the six-across layout was dropped).
 *
 * Warn is confined to the value line. The `sub` line follows up/down polarity but never
 * warn, and the `hint` line stays `text-ink-subtle` unconditionally — both are small
 * text, where 3.68:1 would be a real failure and no size change would rescue it.
 */
const props = defineProps<{ tile: SummaryTile }>()

const valueColor = computed(() => {
  switch (props.tile.sign) {
    case 'up':
      return 'text-up'
    case 'down':
      return 'text-down'
    case 'warn':
      return 'text-warn'
    default:
      return 'text-ink'
  }
})

/** `sub` is small text, so it may never carry the warn token (see the note above). */
const subColor = computed(() => (props.tile.sign === 'warn' ? 'text-ink-muted' : valueColor.value))
</script>

<template>
  <div class="rounded-lg border border-line bg-panel p-4">
    <p class="text-xs font-medium uppercase tracking-wide text-ink-subtle">{{ tile.label }}</p>
    <p class="numeric mt-1 font-semibold" :class="[valueColor, tile.hero ? 'text-2xl' : 'text-xl']">
      {{ tile.value }}
    </p>
    <p v-if="tile.sub" class="numeric mt-0.5 text-sm" :class="subColor">{{ tile.sub }}</p>
    <p v-if="tile.hint" class="mt-1 text-xs text-ink-subtle">{{ tile.hint }}</p>
  </div>
</template>
