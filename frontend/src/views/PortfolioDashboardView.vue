<script setup lang="ts">
import PagePlaceholder from '@/components/PagePlaceholder.vue'

// `props: true` on the route passes the portfolio id; the router guard also
// mirrors it into the active-portfolio store so the side nav scopes correctly.
const props = defineProps<{ id: string }>()
</script>

<template>
  <PagePlaceholder
    title="Dashboard"
    :subtitle="`Portfolio #${props.id}`"
    note="The candlestick dashboard, stat tiles, and allocation donuts land in milestone M6."
  />
</template>
