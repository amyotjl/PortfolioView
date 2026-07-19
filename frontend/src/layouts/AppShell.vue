<script setup lang="ts">
import TopBar from '@/components/layout/TopBar.vue'
import SideNav from '@/components/layout/SideNav.vue'

/**
 * The signed-in chrome: fixed top bar + left rail + scrollable content area.
 * Route views render into the default slot. Kept thin — a composition surface,
 * no feature logic (per the Vue best-practices skill).
 */
</script>

<template>
  <div class="flex h-full flex-col">
    <TopBar />
    <div class="flex min-h-0 flex-1">
      <aside class="hidden w-56 shrink-0 border-r border-line bg-panel md:block">
        <SideNav />
      </aside>
      <main class="min-w-0 flex-1 overflow-y-auto">
        <div class="mx-auto w-full max-w-[1400px] p-4 sm:p-6">
          <slot />
        </div>
      </main>
    </div>
  </div>
</template>
