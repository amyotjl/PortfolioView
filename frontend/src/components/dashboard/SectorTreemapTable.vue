<script setup lang="ts">
import { computed } from 'vue'
import { sectorTreemapNodes } from '@/charts/treemap'
import { chartTheme } from '@/charts/theme'
import { useThemeStore } from '@/stores/theme'
import { formatCurrency, formatPercent } from '@/lib/format'
import type { Allocations } from '@/types'

/**
 * Accessible table twin of the sector treemap — the WCAG-clean equivalent, and
 * the only place every holding's exact figures are guaranteed readable (a small
 * tile's label is truncated by design). The hierarchy flattens to sector rows
 * followed by their indented holdings, so it scans in the same order the treemap
 * lays out.
 *
 * It reuses the chart's own pure hierarchy builder rather than re-deriving the
 * grouping, so the two views can never disagree about which sector a holding is
 * in. (The theme is only needed because the builder also resolves colors.)
 */
const props = defineProps<{ allocations: Allocations }>()

const themeStore = useThemeStore()

interface Row {
  key: string
  name: string
  value: string
  weight: string
  isSector: boolean
}

const rows = computed<Row[]>(() => {
  const nodes = sectorTreemapNodes(props.allocations, chartTheme(themeStore.theme))
  return nodes.flatMap((node) => [
    {
      key: `sector:${node.name}`,
      name: node.name,
      value: formatCurrency(node.valueStr),
      weight: formatPercent(node.weightStr),
      isSector: true,
    },
    ...node.children.map((child) => ({
      key: `${node.name}:${child.name}`,
      name: child.name,
      value: formatCurrency(child.valueStr),
      weight: formatPercent(child.weightStr),
      isSector: false,
    })),
  ])
})
</script>

<template>
  <div class="max-h-[420px] overflow-auto">
    <table class="w-full text-sm">
      <caption class="sr-only">
        Allocation value and weight by sector, with each sector's holdings
      </caption>
      <thead class="sticky top-0 bg-panel text-left text-xs text-ink-subtle">
        <tr class="border-b border-line">
          <th scope="col" class="px-3 py-2 font-medium">Sector / holding</th>
          <th scope="col" class="px-3 py-2 text-right font-medium">Value</th>
          <th scope="col" class="px-3 py-2 text-right font-medium">Weight</th>
        </tr>
      </thead>
      <tbody>
        <tr v-for="row in rows" :key="row.key" class="border-b border-line/60">
          <!--
            A sector row is a row header for the holdings beneath it; the indent is
            decorative, so the scope is what actually conveys the nesting.
          -->
          <component
            :is="row.isSector ? 'th' : 'td'"
            :scope="row.isSector ? 'rowgroup' : undefined"
            class="px-3 py-1.5 text-left"
            :class="row.isSector ? 'font-semibold text-ink' : 'pl-7 font-normal text-ink-muted'"
          >
            {{ row.name }}
          </component>
          <td
            class="numeric px-3 py-1.5 text-right"
            :class="row.isSector ? 'text-ink' : 'text-ink-muted'"
          >
            {{ row.value }}
          </td>
          <td
            class="numeric px-3 py-1.5 text-right"
            :class="row.isSector ? 'font-semibold text-ink' : 'text-ink-muted'"
          >
            {{ row.weight }}
          </td>
        </tr>
      </tbody>
    </table>
  </div>
</template>
