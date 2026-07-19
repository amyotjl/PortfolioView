<script setup lang="ts">
import PagePlaceholder from '@/components/PagePlaceholder.vue'

const props = defineProps<{ id: string }>()
</script>

<template>
  <PagePlaceholder
    title="Recurring"
    :subtitle="`Portfolio #${props.id}`"
    note="Recurring rules, the next-run preview, and paused-rule reasons land in milestone M7."
  />
</template>
