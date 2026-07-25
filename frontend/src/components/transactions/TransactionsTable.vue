<script setup lang="ts">
import DataTable from 'primevue/datatable'
import Column from 'primevue/column'
import Tag from 'primevue/tag'
import Button from 'primevue/button'
import { formatCurrency, formatDate } from '@/lib/format'
import { buttonPt, dataTablePt, tagPt } from '@/primevue/pt'
import type { Transaction } from '@/types'

/**
 * Presentational transactions table. Owns no data and no mutations — the parent
 * passes rows and handles `edit`/`delete`, matching PortfolioCard's split.
 *
 * Decimal strings (shares/price/fees) are rendered verbatim or through the
 * decimal-safe formatters; nothing here converts them to numbers.
 */
const props = defineProps<{
  transactions: readonly Transaction[]
  loading?: boolean
  busyId?: number | null
}>()

const emit = defineEmits<{
  edit: [transaction: Transaction]
  delete: [transaction: Transaction]
}>()

const NUMERIC_CELL = 'px-3 py-2.5 text-right align-middle tabular-nums text-ink'
const NUMERIC_HEADER =
  'whitespace-nowrap px-3 py-2.5 text-right text-xs font-semibold uppercase tracking-wide text-ink-subtle'
</script>

<template>
  <DataTable
    :value="[...props.transactions]"
    data-key="id"
    :loading="props.loading"
    row-hover
    :pt="dataTablePt"
  >
    <template #empty>
      <span>No transactions yet.</span>
    </template>

    <Column field="executed_on" header="Date">
      <template #body="{ data }">
        <span class="whitespace-nowrap tabular-nums">{{ formatDate(data.executed_on) }}</span>
      </template>
    </Column>

    <Column field="symbol" header="Ticker">
      <template #body="{ data }">
        <span class="font-medium">{{ data.symbol }}</span>
        <!--
          DRIP rows are excluded from the dashboard's cash-flow bars (they are not
          new money), so the table flags them or the two views look inconsistent.
        -->
        <span v-if="data.kind === 'dividend_reinvestment'" class="ml-2 text-xs text-ink-subtle">
          DRIP
        </span>
      </template>
    </Column>

    <Column field="side" header="Side">
      <template #body="{ data }">
        <Tag
          :value="data.side === 'buy' ? 'Buy' : 'Sell'"
          :severity="data.side === 'buy' ? 'info' : 'secondary'"
          :pt="tagPt"
        />
      </template>
    </Column>

    <Column
      field="shares"
      header="Shares"
      :pt="{ headerCell: NUMERIC_HEADER, bodyCell: NUMERIC_CELL }"
    >
      <template #body="{ data }">{{ data.shares }}</template>
    </Column>

    <Column
      field="price"
      header="Price"
      :pt="{ headerCell: NUMERIC_HEADER, bodyCell: NUMERIC_CELL }"
    >
      <template #body="{ data }">{{ formatCurrency(data.price) }}</template>
    </Column>

    <Column field="fees" header="Fees" :pt="{ headerCell: NUMERIC_HEADER, bodyCell: NUMERIC_CELL }">
      <template #body="{ data }">{{ formatCurrency(data.fees) }}</template>
    </Column>

    <Column header="Actions" :pt="{ headerCell: NUMERIC_HEADER, bodyCell: NUMERIC_CELL }">
      <template #body="{ data }">
        <div class="flex justify-end gap-1">
          <Button
            text
            label="Edit"
            :disabled="props.busyId === data.id"
            :aria-label="`Edit ${data.side} of ${data.shares} ${data.symbol} on ${data.executed_on}`"
            :pt="buttonPt"
            @click="emit('edit', data)"
          />
          <Button
            text
            label="Delete"
            :disabled="props.busyId === data.id"
            :aria-label="`Delete ${data.side} of ${data.shares} ${data.symbol} on ${data.executed_on}`"
            :pt="buttonPt"
            @click="emit('delete', data)"
          />
        </div>
      </template>
    </Column>
  </DataTable>
</template>
