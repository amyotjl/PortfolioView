<script setup lang="ts">
import { computed, shallowRef, useTemplateRef } from 'vue'
import Button from 'primevue/button'
import Paginator from 'primevue/paginator'
import Toast from 'primevue/toast'
import { useToast } from 'primevue/usetoast'
import TransactionsTable from '@/components/transactions/TransactionsTable.vue'
import TransactionFormDrawer from '@/components/transactions/TransactionFormDrawer.vue'
import CashSection from '@/components/cash/CashSection.vue'
import ConfirmDialog from '@/components/ui/ConfirmDialog.vue'
import {
  useTransactionsQuery,
  useCreateTransaction,
  useUpdateTransaction,
  useDeleteTransaction,
} from '@/composables/useTransactions'
import { useAllocationsQuery } from '@/composables/useAllocations'
import { buildInstrumentIdMap } from '@/lib/instrumentIds'
import { mapApiError } from '@/lib/formErrors'
import { buttonPt, paginatorPt, toastPt } from '@/primevue/pt'
import type { TransactionFormValues } from '@/forms/transaction'
import type { Transaction } from '@/types'

/**
 * Transactions page (#49): the trade list, its create/edit drawer, and the delete
 * confirmation — plus the cash ledger above them (#80).
 *
 * This view owns the TRADE mutations (not the drawer) so the optimistic insert and
 * its undo toast can be coordinated in one place — see `onSubmit` below. `CashSection`
 * is a self-contained feature container that owns its own query and mutations, so
 * nothing about cash is threaded through here.
 */
const props = defineProps<{ id: string }>()
const portfolioId = computed(() => Number(props.id))

const page = shallowRef(1)
const { transactions, meta, status, isEmpty, refetch } = useTransactionsQuery(portfolioId, page)

// Allocations are already cached for the dashboard; reusing them widens the
// symbol -> instrument_id map to currently-held instruments whose transactions
// may sit on another page of the list. See lib/instrumentIds.ts.
const { allocations } = useAllocationsQuery(portfolioId)
const instrumentIds = computed(() => buildInstrumentIdMap(transactions.value, allocations.value))

const createMutation = useCreateTransaction(portfolioId)
const updateMutation = useUpdateTransaction(portfolioId)
const deleteMutation = useDeleteTransaction(portfolioId)

const toast = useToast()

// --- Create / edit -----------------------------------------------------------

const drawerVisible = shallowRef(false)
const editingTransaction = shallowRef<Transaction | null>(null)
const drawer = useTemplateRef<{ applyServerError: (error: unknown) => void }>('drawer')

/**
 * Provisional row shown while the create request is in flight. Given a negative
 * id so it can never collide with a real one (and so the table's `data-key`
 * stays unique), and rendered ahead of the server rows.
 */
const optimisticRow = shallowRef<Transaction | null>(null)

const rows = computed<Transaction[]>(() =>
  optimisticRow.value ? [optimisticRow.value, ...transactions.value] : [...transactions.value],
)

const isSaving = computed(() => createMutation.isLoading.value || updateMutation.isLoading.value)

function openCreate(): void {
  editingTransaction.value = null
  drawerVisible.value = true
}

function openEdit(transaction: Transaction): void {
  editingTransaction.value = transaction
  drawerVisible.value = true
}

/** Shape the form values into a row the table can render before the server replies. */
function toOptimisticRow(values: TransactionFormValues): Transaction {
  const now = new Date().toISOString()
  return {
    id: -1,
    portfolio_id: portfolioId.value,
    // Unknown until the server resolves the symbol; only used for display here.
    instrument_id: -1,
    symbol: values.symbol,
    side: values.side,
    kind: values.kind,
    shares: values.shares,
    price: values.price,
    fees: values.fees,
    executed_on: values.executed_on,
    notes: values.notes,
    recurring_transaction_id: null,
    created_at: now,
    updated_at: now,
  }
}

async function onSubmit(values: TransactionFormValues): Promise<void> {
  const target = editingTransaction.value

  if (target) {
    // Edits are not optimistic: an edit can be rejected by the position replay
    // for a date the user cannot see in this row, so showing the new values as
    // if accepted would be actively misleading.
    try {
      await updateMutation.mutateAsync({ id: target.id, input: values })
      drawerVisible.value = false
      toast.add({
        severity: 'success',
        summary: 'Transaction updated',
        detail: `${values.symbol} on ${values.executed_on}`,
        life: 4000,
      })
    } catch (error) {
      drawer.value?.applyServerError(error)
    }
    return
  }

  // Optimistic create (#49 AC): the provisional row appears in the table at once,
  // and is rolled back if the server rejects.
  //
  // THE DRAWER CLOSES ONLY ON SUCCESS, and that ordering is load-bearing. Closing
  // it up-front and reopening on failure looked equivalent but silently destroyed
  // the failure path: reopening re-runs the drawer's `watch(visible)` seed, which
  // calls resetForm() and clears formError — and because watchers flush on the next
  // tick, it ran AFTER applyServerError() and wiped both the message and everything
  // the user had typed. Keeping the drawer mounted means the 422 lands on a form
  // that still holds its input. Caught by acceptance-criteria verification.
  optimisticRow.value = toOptimisticRow(values)

  try {
    const created = await createMutation.mutateAsync(values)
    optimisticRow.value = null
    drawerVisible.value = false
    offerUndo(created.transaction)
  } catch (error) {
    // Roll back the provisional row and map the envelope onto the fields (a
    // no-short-position violation arrives under `base` and names the first
    // offending date).
    optimisticRow.value = null
    drawer.value?.applyServerError(error)
  }
}

/**
 * Undo toast for a successful create.
 *
 * "Undo" DELETES the transaction the server just made. That is the only honest
 * undo available: the row really exists now, and removing it has to go through
 * the same position replay as any other delete — which can legitimately fail if
 * a later sell now depends on these shares. So the undo reports its own errors
 * instead of assuming it worked.
 *
 * PrimeVue's ToastMessageOptions has no payload field to hang a callback on, so
 * the pending action lives here and the grouped <Toast group="tx-undo"> outlet in
 * this view's template renders the button.
 */
const UNDO_GROUP = 'tx-undo'
const undoTarget = shallowRef<Transaction | null>(null)

function offerUndo(created: Transaction): void {
  undoTarget.value = created
  toast.add({
    group: UNDO_GROUP,
    severity: 'success',
    summary: 'Transaction added',
    detail: `${created.side === 'buy' ? 'Bought' : 'Sold'} ${created.shares} ${created.symbol}`,
    life: 8000,
  })
}

async function runUndo(): Promise<void> {
  const target = undoTarget.value
  if (!target) return
  undoTarget.value = null
  toast.removeGroup(UNDO_GROUP)

  try {
    await deleteMutation.mutateAsync(target.id)
    toast.add({ severity: 'info', summary: 'Transaction removed', life: 3000 })
  } catch (error) {
    toast.add({
      severity: 'error',
      summary: 'Could not undo',
      detail:
        mapApiError(error, []).formMessage ??
        'The transaction is still there — remove it from the table instead.',
      life: 6000,
    })
  }
}

// --- Delete ------------------------------------------------------------------

const confirmVisible = shallowRef(false)
const deletingTransaction = shallowRef<Transaction | null>(null)
const deleteError = shallowRef<string | null>(null)
const deletePending = computed(() => deleteMutation.isLoading.value)

function askDelete(transaction: Transaction): void {
  deletingTransaction.value = transaction
  deleteError.value = null
  confirmVisible.value = true
}

const deleteMessage = computed(() => {
  const target = deletingTransaction.value
  if (!target) return ''
  const verb = target.side === 'buy' ? 'buy' : 'sell'
  return `Delete the ${verb} of ${target.shares} ${target.symbol} on ${target.executed_on}? This can’t be undone.`
})

async function confirmDelete(): Promise<void> {
  const target = deletingTransaction.value
  if (!target) return
  deleteError.value = null
  try {
    await deleteMutation.mutateAsync(target.id)
    confirmVisible.value = false
  } catch (error) {
    // A delete that would strand a later sell is rejected with a 422 naming the
    // offending date — surface that message rather than a generic failure.
    deleteError.value =
      mapApiError(error, []).formMessage ?? 'Could not delete the transaction.'
  }
}

// --- Pagination --------------------------------------------------------------

const perPage = computed(() => meta.value?.per_page ?? 50)
const totalRecords = computed(() => meta.value?.total_count ?? 0)
const firstRecord = computed(() => (page.value - 1) * perPage.value)
const showPaginator = computed(() => (meta.value?.total_pages ?? 0) > 1)

function onPageChange(event: { page: number }): void {
  page.value = event.page + 1
}
</script>

<template>
  <section>
    <header class="mb-6">
      <h1 class="text-xl font-semibold tracking-tight text-ink">Transactions</h1>
      <p class="mt-1 text-sm text-ink-muted">
        This portfolio’s cash movements and trades, most recent first.
      </p>
    </header>

    <!--
      Cash above trades: it is the shorter list, it is what a reader checks when the
      total does not match their broker, and a deposit is what unlocks the
      deposit-based return basis the trades below are measured against.
    -->
    <CashSection :portfolio-id="portfolioId" />

    <section aria-label="Trades">
      <header class="mb-3 flex flex-wrap items-start justify-between gap-3">
        <div>
          <h2 class="text-base font-semibold text-ink">Trades</h2>
          <p class="mt-0.5 text-sm text-ink-muted">Every buy and sell in this portfolio.</p>
        </div>
        <Button label="Add transaction" :pt="buttonPt" @click="openCreate" />
      </header>

      <!-- Loading -->
      <div
        v-if="status === 'pending'"
        class="h-64 animate-pulse rounded-lg border border-line bg-panel"
        aria-hidden="true"
      />
      <span v-if="status === 'pending'" class="sr-only">Loading transactions…</span>

      <!-- Error -->
      <div
        v-else-if="status === 'error'"
        class="rounded-lg border border-line bg-panel p-8 text-center"
      >
        <p class="text-sm text-ink">We couldn’t load your transactions.</p>
        <p class="mt-1 text-sm text-ink-muted">Check your connection and try again.</p>
        <Button
          label="Retry"
          severity="secondary"
          class="mt-4"
          :pt="buttonPt"
          @click="() => refetch()"
        />
      </div>

      <!-- Empty (no optimistic row in flight either) -->
      <div
        v-else-if="isEmpty && !optimisticRow"
        class="rounded-lg border border-dashed border-line-strong bg-panel p-10 text-center"
      >
        <h3 class="text-base font-semibold text-ink">No trades yet</h3>
        <p class="mx-auto mt-1 max-w-sm text-sm text-ink-muted">
          Add your first buy to start building this portfolio’s history and performance chart.
        </p>
        <Button label="Add transaction" class="mt-5" :pt="buttonPt" @click="openCreate" />
      </div>

      <!-- List -->
      <div v-else class="overflow-hidden rounded-lg border border-line bg-panel">
        <TransactionsTable
          :transactions="rows"
          :busy-id="optimisticRow ? -1 : null"
          @edit="openEdit"
          @delete="askDelete"
        />
        <Paginator
          v-if="showPaginator"
          :rows="perPage"
          :total-records="totalRecords"
          :first="firstRecord"
          :pt="paginatorPt"
          @page="onPageChange"
        />
      </div>
    </section>

    <TransactionFormDrawer
      ref="drawer"
      v-model:visible="drawerVisible"
      :portfolio-id="portfolioId"
      :transaction="editingTransaction"
      :instrument-ids="instrumentIds"
      :busy="isSaving"
      @submit="onSubmit"
    />

    <ConfirmDialog
      v-model:visible="confirmVisible"
      title="Delete transaction"
      :message="deleteMessage"
      confirm-label="Delete"
      danger
      :pending="deletePending"
      :error="deleteError"
      @confirm="confirmDelete"
    />

    <!--
      Undo outlet for the optimistic create. Grouped so it renders here (with the
      Undo button) instead of in App.vue's default outlet, which handles every
      other notification this page raises.
    -->
    <Toast :group="UNDO_GROUP" :pt="toastPt">
      <template #message="{ message }">
        <div class="flex flex-1 items-start gap-3">
          <div class="flex-1 text-sm">
            <span class="block font-medium text-ink">{{ message.summary }}</span>
            <span class="mt-0.5 block text-ink-muted">{{ message.detail }}</span>
          </div>
          <button
            type="button"
            class="shrink-0 rounded px-2 py-1 text-sm font-semibold text-accent transition-colors hover:bg-accent-soft focus-visible:ring-2 focus-visible:ring-accent-soft"
            @click="runUndo"
          >
            Undo
          </button>
        </div>
      </template>
    </Toast>
  </section>
</template>
