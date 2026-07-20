<script setup lang="ts">
import Dialog from 'primevue/dialog'
import Button from 'primevue/button'
import { dialogPt, buttonPt } from '@/primevue/pt'

/**
 * Generic confirm dialog. The parent owns the action: it listens for `confirm`,
 * runs the work, drives `pending`/`error`, and closes by setting `visible`.
 */
const visible = defineModel<boolean>('visible', { required: true })

withDefaults(
  defineProps<{
    title: string
    message: string
    confirmLabel?: string
    cancelLabel?: string
    danger?: boolean
    pending?: boolean
    error?: string | null
  }>(),
  { confirmLabel: 'Confirm', cancelLabel: 'Cancel', danger: false, pending: false, error: null },
)

const emit = defineEmits<{ confirm: [] }>()
</script>

<template>
  <Dialog
    v-model:visible="visible"
    modal
    :header="title"
    :draggable="false"
    :dismissable-mask="!pending"
    :closable="!pending"
    :pt="dialogPt"
  >
    <p class="text-sm text-ink-muted">{{ message }}</p>
    <p
      v-if="error"
      role="alert"
      class="mt-3 rounded-md border border-down/30 bg-down/10 px-3 py-2 text-sm text-down"
    >
      {{ error }}
    </p>

    <template #footer>
      <Button
        :label="cancelLabel"
        severity="secondary"
        :disabled="pending"
        :pt="buttonPt"
        @click="visible = false"
      />
      <Button
        :label="pending ? 'Working…' : confirmLabel"
        :severity="danger ? 'danger' : undefined"
        :disabled="pending"
        :pt="buttonPt"
        @click="emit('confirm')"
      />
    </template>
  </Dialog>
</template>
