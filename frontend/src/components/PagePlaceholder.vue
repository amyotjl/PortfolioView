<script setup lang="ts">
/**
 * Shared scaffold for pages whose real content lands in a later milestone. Keeps
 * placeholder views thin and visually consistent; the `note` states which issue
 * fills the page in so the shell never reads as accidentally empty.
 */
defineProps<{
  title: string
  subtitle?: string
  note?: string
}>()
</script>

<template>
  <section>
    <header class="mb-6">
      <h1 class="text-xl font-semibold tracking-tight text-ink">{{ title }}</h1>
      <p v-if="subtitle" class="mt-1 text-sm text-ink-muted">{{ subtitle }}</p>
    </header>

    <div
      class="rounded-lg border border-dashed border-line-strong bg-panel p-8 text-center"
    >
      <p class="text-sm text-ink-muted">
        <slot>{{ note ?? 'This page is part of the app shell scaffold.' }}</slot>
      </p>
    </div>
  </section>
</template>
