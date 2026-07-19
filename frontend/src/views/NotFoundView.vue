<script setup lang="ts">
// Catch-all route. Kept inside the app shell so navigation stays available.
</script>

<template>
  <section class="py-16 text-center">
    <p class="numeric text-5xl font-semibold text-ink-subtle">404</p>
    <h1 class="mt-4 text-xl font-semibold tracking-tight text-ink">Page not found</h1>
    <p class="mt-2 text-sm text-ink-muted">That page doesn't exist.</p>
    <RouterLink
      :to="{ name: 'portfolios' }"
      class="mt-6 inline-block rounded-md bg-accent px-4 py-2 text-sm font-medium text-on-accent transition-colors hover:bg-accent-hi"
    >
      Back to portfolios
    </RouterLink>
  </section>
</template>
