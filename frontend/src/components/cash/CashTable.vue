<script setup lang="ts">
import DataTable from 'primevue/datatable'
import Column from 'primevue/column'
import Button from 'primevue/button'
import { cashKindLabel, signedCashAmount } from '@/lib/cash'
import { formatCurrency, formatDate } from '@/lib/format'
import { buttonPt, dataTablePt } from '@/primevue/pt'
import type { CashTransaction } from '@/types'

/**
 * Presentational cash ledger. Owns no data and no mutations — the parent passes
 * rows and handles `edit`/`delete`, matching `TransactionsTable`.
 *
 * Decimal strings are rendered through the decimal-safe formatters; nothing here
 * converts them to numbers.
 *
 * The wire sends a movement's `amount` as an UNSIGNED magnitude with `kind`
 * carrying the direction, so the Type column and the Amount column are two halves
 * of one fact and both are always shown. The sign shown in Amount comes from
 * `signedCashAmount`, which never invents one for a bidirectional kind (`tax`,
 * `fee`) — see lib/cash.ts.
 *
 * Amount is NOT colored by sign. up/down are reserved app-wide for real gain/loss
 * polarity, and a withdrawal is not a loss.
 */
const props = defineProps<{
  cashTransactions: readonly CashTransaction[]
  loading?: boolean
  busyId?: number | null
}>()

const emit = defineEmits<{
  edit: [cashTransaction: CashTransaction]
  delete: [cashTransaction: CashTransaction]
}>()

const NUMERIC_CELL = 'px-3 py-2.5 text-right align-middle tabular-nums text-ink'
const NUMERIC_HEADER =
  'whitespace-nowrap px-3 py-2.5 text-right text-xs font-semibold uppercase tracking-wide text-ink-subtle'

/**
 * Row-naming action labels, e.g. `Delete deposit of $5,000.00 on 2026-08-03`. The
 * magnitude is unsigned here and the date is the raw ISO string, matching
 * TransactionsTable's labels — a screen-reader user needs the row identified, not
 * the arithmetic restated.
 */
function actionLabel(verb: string, row: CashTransaction): string {
  return `${verb} ${cashKindLabel(row.kind).toLowerCase()} of ${formatCurrency(row.amount)} on ${row.occurred_on}`
}
</script>

<template>
  <DataTable
    :value="[...props.cashTransactions]"
    data-key="id"
    :loading="props.loading"
    row-hover
    :pt="dataTablePt"
  >
    <template #empty>
      <span>No cash movements yet.</span>
    </template>

    <Column field="occurred_on" header="Date">
      <template #body="{ data }">
        <span class="whitespace-nowrap tabular-nums">{{ formatDate(data.occurred_on) }}</span>
      </template>
    </Column>

    <Column field="kind" header="Type">
      <template #body="{ data }">
        <span class="font-medium">{{ cashKindLabel(data.kind) }}</span>
      </template>
    </Column>

    <Column
      field="amount"
      header="Amount"
      :pt="{ headerCell: NUMERIC_HEADER, bodyCell: NUMERIC_CELL }"
    >
      <template #body="{ data }">{{ signedCashAmount(data.kind, data.amount) }}</template>
    </Column>

    <Column field="notes" header="Notes">
      <template #body="{ data }">
        <span class="text-ink-muted">{{ data.notes ?? '—' }}</span>
      </template>
    </Column>

    <Column header="Actions" :pt="{ headerCell: NUMERIC_HEADER, bodyCell: NUMERIC_CELL }">
      <template #body="{ data }">
        <div class="flex justify-end gap-1">
          <Button
            text
            label="Edit"
            :disabled="props.busyId === data.id"
            :aria-label="actionLabel('Edit', data)"
            :pt="buttonPt"
            @click="emit('edit', data)"
          />
          <Button
            text
            label="Delete"
            :disabled="props.busyId === data.id"
            :aria-label="actionLabel('Delete', data)"
            :pt="buttonPt"
            @click="emit('delete', data)"
          />
        </div>
      </template>
    </Column>
  </DataTable>
</template>
