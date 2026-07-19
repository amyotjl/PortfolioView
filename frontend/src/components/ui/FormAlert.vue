<script setup lang="ts">
/**
 * Form-level error banner for anything that isn't a single-field failure
 * (invalid credentials, rate limiting, connection errors). Renders nothing when
 * there is no message. `role="alert"` announces it to assistive tech on appear.
 */
defineProps<{
  message?: string | null
}>()
</script>

<template>
  <p
    v-if="message"
    role="alert"
    class="rounded-md border border-down/30 bg-down/10 px-3 py-2 text-sm text-down"
  >
    {{ message }}
  </p>
</template>
