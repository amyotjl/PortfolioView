<script setup lang="ts">
import { computed, useId } from 'vue'

/**
 * Presentational field wrapper: renders the label, the control (default slot),
 * and a hint/error line, wiring the accessibility relationships (label `for`,
 * `aria-describedby`, `aria-invalid`) so each form control stays consistent.
 * The control is provided by the caller via the slot, which receives the
 * generated `id`, the `invalid` flag, and the `describedby` id string to bind.
 */
const props = defineProps<{
  label: string
  error?: string
  hint?: string
  required?: boolean
}>()

const fieldId = useId()
const errorId = `${fieldId}-error`
const hintId = `${fieldId}-hint`

const describedby = computed(() => {
  const ids: string[] = []
  if (props.hint && !props.error) ids.push(hintId)
  if (props.error) ids.push(errorId)
  return ids.length > 0 ? ids.join(' ') : undefined
})
</script>

<template>
  <div class="flex flex-col gap-1.5">
    <label :for="fieldId" class="text-sm font-medium text-ink">
      {{ label }}
      <span v-if="required" class="text-down" aria-hidden="true">*</span>
    </label>

    <slot :id="fieldId" :invalid="Boolean(error)" :describedby="describedby" />

    <p v-if="hint && !error" :id="hintId" class="text-xs text-ink-subtle">{{ hint }}</p>
    <p v-if="error" :id="errorId" role="alert" class="text-xs font-medium text-down">{{ error }}</p>
  </div>
</template>
