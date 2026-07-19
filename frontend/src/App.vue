<script setup lang="ts">
import { computed } from 'vue'
import { useRoute } from 'vue-router'
import AppShell from '@/layouts/AppShell.vue'
import AuthLayout from '@/layouts/AuthLayout.vue'

const route = useRoute()

// Route meta selects the chrome; the RouterView content renders into its slot.
const layout = computed(() => (route.meta.layout === 'auth' ? AuthLayout : AppShell))
</script>

<template>
  <component :is="layout">
    <RouterView />
  </component>
</template>
