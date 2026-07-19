<script setup lang="ts">
import ThemeToggle from '@/components/ThemeToggle.vue'

/** Centered chrome for /login and /register. Route views render into the slot. */
</script>

<template>
  <div class="relative flex min-h-full items-center justify-center p-6">
    <div class="absolute right-4 top-4">
      <ThemeToggle />
    </div>

    <div class="w-full max-w-sm">
      <div class="mb-6 flex items-center gap-2">
        <span
          class="grid h-7 w-7 place-items-center rounded bg-accent text-xs font-bold text-on-accent"
          aria-hidden="true"
        >
          PV
        </span>
        <span class="text-lg font-semibold tracking-tight text-ink">PortfolioView</span>
      </div>

      <div class="rounded-lg border border-line bg-panel p-6">
        <slot />
      </div>
    </div>
  </div>
</template>
