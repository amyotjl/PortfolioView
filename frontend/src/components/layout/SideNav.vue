<script setup lang="ts">
import { computed } from 'vue'
import { storeToRefs } from 'pinia'
import { useRoute, type RouteLocationRaw } from 'vue-router'
import { useActivePortfolioStore } from '@/stores/active-portfolio'

interface NavLink {
  /** Matched against the current route name to decide the active state. */
  name: string
  label: string
  to: RouteLocationRaw
}

const route = useRoute()
const { activeId } = storeToRefs(useActivePortfolioStore())

const globalLinks: NavLink[] = [
  { name: 'portfolios', label: 'Portfolios', to: { name: 'portfolios' } },
  { name: 'settings', label: 'Settings', to: { name: 'settings' } },
]

// Portfolio-scoped links only make sense once a portfolio is selected.
const portfolioLinks = computed<NavLink[]>(() => {
  const id = activeId.value
  if (id === null) return []
  return [
    {
      name: 'portfolio-dashboard',
      label: 'Dashboard',
      to: { name: 'portfolio-dashboard', params: { id } },
    },
    {
      name: 'portfolio-transactions',
      label: 'Transactions',
      to: { name: 'portfolio-transactions', params: { id } },
    },
    {
      name: 'portfolio-recurring',
      label: 'Recurring',
      to: { name: 'portfolio-recurring', params: { id } },
    },
  ]
})

const baseLinkClass =
  'block rounded-md px-3 py-2 text-sm font-medium transition-colors'

function classesFor(link: NavLink): string {
  const isActive = route.name === link.name
  return isActive
    ? `${baseLinkClass} bg-accent-soft text-accent`
    : `${baseLinkClass} text-ink-muted hover:bg-panel-hi hover:text-ink`
}
</script>

<template>
  <nav class="flex h-full flex-col gap-6 p-3" aria-label="Primary">
    <ul class="flex flex-col gap-1">
      <li v-for="link in globalLinks" :key="link.name">
        <RouterLink
          :to="link.to"
          :class="classesFor(link)"
          :aria-current="route.name === link.name ? 'page' : undefined"
        >
          {{ link.label }}
        </RouterLink>
      </li>
    </ul>

    <div v-if="portfolioLinks.length > 0" class="flex flex-col gap-1">
      <p class="px-3 pb-1 text-[0.7rem] font-semibold uppercase tracking-wider text-ink-subtle">
        This portfolio
      </p>
      <ul class="flex flex-col gap-1">
        <li v-for="link in portfolioLinks" :key="link.name">
          <RouterLink
            :to="link.to"
            :class="classesFor(link)"
            :aria-current="route.name === link.name ? 'page' : undefined"
          >
            {{ link.label }}
          </RouterLink>
        </li>
      </ul>
    </div>
  </nav>
</template>
