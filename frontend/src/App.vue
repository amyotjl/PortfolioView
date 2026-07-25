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
</script>

<template>
  <component :is="layout">
    <RouterView />
  </component>

  <!--
    App-wide outlet for ungrouped notifications, mounted outside the layout so a
    toast survives a route change. Views needing a custom message body (e.g. the
    transactions page's undo button) mount their own grouped <Toast group="…"/>.
  -->
  <Toast :pt="toastPt" />
</template>
