<script setup lang="ts">
import { computed } from 'vue'
import { useRoute } from 'vue-router'
import Toast from 'primevue/toast'
import AppShell from '@/layouts/AppShell.vue'
import AuthLayout from '@/layouts/AuthLayout.vue'
import { toastPt } from '@/primevue/pt'

const route = useRoute()

// Route meta selects the chrome; the RouterView content renders into its slot.
const layout = computed(() => (route.meta.layout === 'auth' ? AuthLayout : AppShell))

/**
 * The router guard is async (it awaits the /session bootstrap on first load), and
 * until it resolves `route.meta` is empty — so `layout` would fall back to
 * AppShell even for an auth route. Mounting AppShell speculatively is not free:
 * its top bar fetches authenticated-only data, which on a signed-out visit 401s
 * and bounces the visitor to /login. Wait for a resolved route (a named match)
 * before committing to any chrome. See also the `enabled` guard in
 * usePortfoliosQuery — belt and braces, since either alone fixes the symptom but
 * both are correct in their own right.
 */
const isRouteResolved = computed(() => Boolean(route.name))
</script>

<template>
  <component :is="layout" v-if="isRouteResolved">
    <RouterView />
  </component>

  <!--
    App-wide outlet for ungrouped notifications, mounted outside the layout so a
    toast survives a route change. Views needing a custom message body (e.g. the
    transactions page's undo button) mount their own grouped <Toast group="…"/>.
  -->
  <Toast :pt="toastPt" />
</template>
