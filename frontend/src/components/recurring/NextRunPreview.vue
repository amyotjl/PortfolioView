<script setup lang="ts">
import { formatDate } from '@/lib/format'
import type { RecurringRunDate } from '@/types'

/**
 * The next 3 server-computed run dates (#50). Purely presentational — the parent
 * owns the preview call and re-runs it as inputs change.
 *
 * Two dates per slot, and the distinction matters: `scheduled_for` is the
 * calendar slot the frequency+anchor produce, while `execution_on` is the first
 * trading day on or after it — so a slot landing on a weekend or holiday shows a
 * later execution date. `execution_on` is null when the price calendar does not
 * reach that far yet, which is normal for slots months out, so it renders as an
 * honest "trading day not known yet" rather than a guess or an error.
 */
const props = defineProps<{
  runDates: readonly RecurringRunDate[]
  loading?: boolean
}>()
</script>

<template>
  <div class="rounded-md border border-line bg-panel-hi/50 px-3 py-3">
    <div class="flex items-center justify-between gap-2">
      <h3 class="text-sm font-medium text-ink">Next 3 runs</h3>
      <span v-if="props.loading" class="text-xs text-ink-subtle">Calculating…</span>
    </div>

    <p v-if="!props.loading && props.runDates.length === 0" class="mt-2 text-sm text-ink-subtle">
      Pick a frequency and start date to preview the schedule.
    </p>

    <ol v-else class="mt-2 flex flex-col gap-1.5">
      <li
        v-for="(run, index) in props.runDates"
        :key="`${run.scheduled_for}-${index}`"
        class="flex flex-wrap items-baseline justify-between gap-x-3 text-sm"
      >
        <span class="tabular-nums text-ink">{{ formatDate(run.scheduled_for) }}</span>

        <span
          v-if="run.execution_on && run.execution_on !== run.scheduled_for"
          class="text-xs text-ink-muted"
        >
          buys on {{ formatDate(run.execution_on) }}
        </span>
        <span v-else-if="!run.execution_on" class="text-xs text-ink-subtle">
          trading day not known yet
        </span>
      </li>
    </ol>

    <p class="mt-2.5 text-xs text-ink-subtle">
      Scheduled dates that fall on a weekend or holiday buy on the next trading day.
    </p>
  </div>
</template>
