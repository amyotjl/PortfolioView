<script setup lang="ts">
import { computed } from 'vue'
import Tag from 'primevue/tag'
import Button from 'primevue/button'
import { formatCurrency, formatDate } from '@/lib/format'
import { buttonPt, tagPt } from '@/primevue/pt'
import type { RecurringTransaction } from '@/types'

/**
 * One recurring rule. Presentational — the parent owns every mutation.
 *
 * A PAUSED RULE MUST EXPLAIN ITSELF (#50 AC). The materializer pauses a rule
 * after repeated failures and records why in `paused_reason`; that text is the
 * whole reason the user can act, so it is rendered prominently rather than hidden
 * behind a tooltip or an icon.
 */
const props = defineProps<{ rule: RecurringTransaction; busy?: boolean }>()

const emit = defineEmits<{
  edit: [rule: RecurringTransaction]
  toggle: [rule: RecurringTransaction]
  delete: [rule: RecurringTransaction]
}>()

const FREQUENCY_LABELS: Record<RecurringTransaction['frequency'], string> = {
  weekly: 'Weekly',
  biweekly: 'Every 2 weeks',
  monthly: 'Monthly',
  quarterly: 'Quarterly',
}

/** Paused-by-the-system reads differently from paused-by-the-user. */
const isPausedBySystem = computed(() => !props.rule.active && Boolean(props.rule.paused_reason))

const statusLabel = computed(() => {
  if (props.rule.active) return 'Active'
  return isPausedBySystem.value ? 'Paused' : 'Off'
})

const statusSeverity = computed(() => {
  if (props.rule.active) return 'info'
  return isPausedBySystem.value ? 'warn' : 'secondary'
})

const amountLabel = computed(() => {
  const { amount_type, dollar_amount, share_amount } = props.rule
  if (amount_type === 'dollars') {
    return dollar_amount ? `${formatCurrency(dollar_amount)} per run` : 'Amount not set'
  }
  return share_amount ? `${share_amount} shares per run` : 'Shares not set'
})
</script>

<template>
  <article class="flex flex-col gap-3 rounded-lg border border-line bg-panel p-4">
    <header class="flex items-start justify-between gap-3">
      <div>
        <h2 class="text-base font-semibold text-ink">{{ props.rule.symbol }}</h2>
        <p class="mt-0.5 text-sm text-ink-muted">
          {{ FREQUENCY_LABELS[props.rule.frequency] }} · {{ amountLabel }}
        </p>
      </div>
      <Tag :value="statusLabel" :severity="statusSeverity" :pt="tagPt" />
    </header>

    <dl class="grid grid-cols-2 gap-x-4 gap-y-1.5 text-sm">
      <div>
        <dt class="text-xs uppercase tracking-wide text-ink-subtle">Next run</dt>
        <dd class="tabular-nums text-ink">
          {{ props.rule.active ? formatDate(props.rule.next_run_on) : '—' }}
        </dd>
      </div>
      <div>
        <dt class="text-xs uppercase tracking-wide text-ink-subtle">Ends</dt>
        <dd class="tabular-nums text-ink">
          {{ props.rule.end_on ? formatDate(props.rule.end_on) : 'No end date' }}
        </dd>
      </div>
    </dl>

    <!--
      role="alert" (unlike the drawer's advisory notices): a rule that stopped
      buying without the user asking is something they need to know about now.
    -->
    <p
      v-if="isPausedBySystem"
      role="alert"
      class="rounded-md border border-warn bg-warn-soft px-3 py-2 text-sm text-ink"
    >
      <span class="font-medium">Paused:</span> {{ props.rule.paused_reason }}
      <span v-if="props.rule.consecutive_skips > 0" class="text-ink-muted">
        ({{ props.rule.consecutive_skips }} skipped
        {{ props.rule.consecutive_skips === 1 ? 'run' : 'runs' }})
      </span>
    </p>

    <footer class="flex flex-wrap justify-end gap-1">
      <Button
        text
        :label="props.rule.active ? 'Pause' : 'Resume'"
        :disabled="props.busy"
        :aria-label="`${props.rule.active ? 'Pause' : 'Resume'} the ${props.rule.symbol} recurring buy`"
        :pt="buttonPt"
        @click="emit('toggle', props.rule)"
      />
      <Button
        text
        label="Edit"
        :disabled="props.busy"
        :aria-label="`Edit the ${props.rule.symbol} recurring buy`"
        :pt="buttonPt"
        @click="emit('edit', props.rule)"
      />
      <Button
        text
        label="Delete"
        :disabled="props.busy"
        :aria-label="`Delete the ${props.rule.symbol} recurring buy`"
        :pt="buttonPt"
        @click="emit('delete', props.rule)"
      />
    </footer>
  </article>
</template>
