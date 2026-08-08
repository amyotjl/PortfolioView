<script setup lang="ts">
import { computed } from 'vue'

/**
 * Advisory notice: something the reader should know, that is NOT an error and does
 * not block anything. Renders nothing when there is no message.
 *
 * NOT `FormAlert`, and the difference is load-bearing. FormAlert is `role="alert"`
 * in loss-red for form-level *errors* — an assertive announcement that interrupts a
 * screen-reader user. A negative cash balance is neither an error nor form-level,
 * and #80's decision 2 explicitly forbids blocking on it, so this component is
 * `role="status"` (polite). Do not "upgrade" it to `role="alert"`.
 *
 * WHY IT EXISTS: this exact markup was inlined twice in `TransactionFormDrawer.vue`
 * — the weekend "market closed" note and the advisory sell pre-flight — and cash
 * needs it in three more places. Promoted to one component so the tone, the ARIA
 * role and the contrast decisions below are made once.
 *
 * CONTRAST. `text-warn` measures ≈3.6:1 and FAILS the 4.5:1 requirement for normal
 * body text, so the warn tone carries its color on the BORDER (a non-text element,
 * not subject to 4.5:1) with the body text at full `text-ink`. That is why this is
 * not simply amber text.
 *
 * The default slot renders after the message, for a live suffix such as the sell
 * pre-flight's "(checking…)".
 */
const props = defineProps<{
  message?: string | null
  tone?: 'warn' | 'info'
}>()

const toneClass = computed(() =>
  (props.tone ?? 'warn') === 'warn'
    ? 'border-warn bg-warn-soft text-ink'
    : 'border-line bg-panel-hi text-ink-muted',
)
</script>

<template>
  <p
    v-if="message"
    role="status"
    class="rounded-md border px-3 py-2 text-sm"
    :class="toneClass"
  >
    {{ message }}
    <slot />
  </p>
</template>
