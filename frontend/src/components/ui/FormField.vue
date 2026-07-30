<script setup lang="ts">
import { computed, useId } from 'vue'
import { fieldErrorId, fieldHintId, fieldLabelId } from '@/lib/fieldIds'

/**
 * Presentational field wrapper: renders the label, the control (default slot),
 * and a hint/error line, wiring the accessibility relationships (label `for`,
 * `aria-describedby`, `aria-invalid`) so each form control stays consistent.
 * The control is provided by the caller via the slot, which receives the
 * generated `id`, the `invalid` flag, the `describedby` id string to bind, and
 * the label's own `labelledby` id.
 *
 * `labelledby` exists because `for`/`id` only names a *labelable* element
 * (input/select/textarea/button/…). PrimeVue's unstyled `Select` renders its
 * combobox as a `<span>`, so the association silently does nothing there and
 * the control has to be named with `aria-labelledby` instead (#65). Controls
 * that render a real form element don't need it and should keep using `id`.
 */
const props = defineProps<{
  label: string
  error?: string
  hint?: string
  required?: boolean
}>()

const fieldId = useId()
const labelId = fieldLabelId(fieldId)
const errorId = fieldErrorId(fieldId)
const hintId = fieldHintId(fieldId)

const describedby = computed(() => {
  const ids: string[] = []
  if (props.hint && !props.error) ids.push(hintId)
  if (props.error) ids.push(errorId)
  return ids.length > 0 ? ids.join(' ') : undefined
})
</script>

<template>
  <div class="flex flex-col gap-1.5">
    <label :id="labelId" :for="fieldId" class="text-sm font-medium text-ink">
      {{ label }}
      <span v-if="required" class="text-down" aria-hidden="true">*</span>
    </label>

    <slot
      :id="fieldId"
      :labelledby="labelId"
      :invalid="Boolean(error)"
      :describedby="describedby"
    />

    <p v-if="hint && !error" :id="hintId" class="text-xs text-ink-subtle">{{ hint }}</p>
    <p v-if="error" :id="errorId" role="alert" class="text-xs font-medium text-down">{{ error }}</p>
  </div>
</template>
