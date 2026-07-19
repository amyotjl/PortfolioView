<script setup lang="ts">
import PagePlaceholder from '@/components/PagePlaceholder.vue'

const props = defineProps<{ id: string }>()
</script>

<template>
  <PagePlaceholder
    title="Transactions"
    :subtitle="`Portfolio #${props.id}`"
    note="The transactions table and add/edit drawer land in milestone M7."
  />
</template>
