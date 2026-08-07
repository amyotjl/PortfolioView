<script setup lang="ts">
import { computed, shallowRef, useTemplateRef } from 'vue'
import Button from 'primevue/button'
import Paginator from 'primevue/paginator'
import { useToast } from 'primevue/usetoast'
import CashTable from '@/components/cash/CashTable.vue'
import CashFormDrawer from '@/components/cash/CashFormDrawer.vue'
import AdvisoryNotice from '@/components/ui/AdvisoryNotice.vue'
import ConfirmDialog from '@/components/ui/ConfirmDialog.vue'
import {
  useCashQuery,
  useCreateCashTransaction,
  useUpdateCashTransaction,
  useDeleteCashTransaction,
} from '@/composables/useCashTransactions'
import { useSummaryQuery } from '@/composables/useSummary'
import { cashKindLabel, negativeCashNotice } from '@/lib/cash'
import { toCashInput, type CashFormValues } from '@/forms/cash'
import { mapApiError } from '@/lib/formErrors'
import { formatCurrency } from '@/lib/format'
import { buttonPt, paginatorPt } from '@/primevue/pt'
import type { CashTransaction } from '@/types'

/**
 * The cash ledger section of the Transactions page (#80) — its own feature
 * container, so `TransactionsView` stays a thin composition surface.
 *
 * It sits ABOVE the trades table on the same page, deliberately not on a route of
 * its own and not merged into one ledger: both lists page at 50, so page 1 of
 * trades ∪ page 1 of cash is NOT the 50 most recent events. Same page keeps "why is
 * my cash negative?" a one-screen investigation; separate tables keep pagination
 * honest.
 *
 * The balance comes from /summary, whose query Pinia Colada dedupes with the
 * dashboard's — no prop threading, no second request. `cash_balance === null` means
 * "does not track cash" and is NOT zero, which is why every consumer below passes it
 * through untouched.
 */
const props = defineProps<{ portfolioId: number }>()

const page = shallowRef(1)
const { cashTransactions, meta, status, isEmpty, refetch } = useCashQuery(
  () => props.portfolioId,
  page,
)

const { summary } = useSummaryQuery(() => props.portfolioId)
const cashBalance = computed<string | null>(() => summary.value?.cash_balance ?? null)

/**
 * Advisory for an already-negative balance, at the top of the section. Driven by
 * /summary (not by a windowed payload), so it does not re-announce on a range change
 * elsewhere in the app.
 */
const negativeNotice = computed(() => negativeCashNotice(cashBalance.value))

const createMutation = useCreateCashTransaction(() => props.portfolioId)
const updateMutation = useUpdateCashTransaction(() => props.portfolioId)
const deleteMutation = useDeleteCashTransaction(() => props.portfolioId)

const toast = useToast()

// --- Create / edit -----------------------------------------------------------

const drawerVisible = shallowRef(false)
const editingCash = shallowRef<CashTransaction | null>(null)
const drawer = useTemplateRef<{ applyServerError: (error: unknown) => void }>('drawer')

const isSaving = computed(() => createMutation.isLoading.value || updateMutation.isLoading.value)

function openCreate(): void {
  editingCash.value = null
  drawerVisible.value = true
}

function openEdit(cashTransaction: CashTransaction): void {
  editingCash.value = cashTransaction
  drawerVisible.value = true
}

/**
 * No optimistic row here, unlike the trades table.
 *
 * The response's `meta.cash_balance` is the whole point of the save — it is what the
 * toast reports and what the negative advisory keys on — and a provisional row would
 * have to invent a balance to sit beside. A cash write is a single INSERT with no
 * position replay, so it is also fast enough not to need one.
 */
async function onSubmit(values: CashFormValues): Promise<void> {
  const target = editingCash.value
  const input = toCashInput(values)

  try {
    const response = target
      ? await updateMutation.mutateAsync({ id: target.id, input })
      : await createMutation.mutateAsync(input)

    // THE DRAWER CLOSES ONLY ON SUCCESS. Closing it up-front and reopening on
    // failure re-runs the drawer's watch(visible) seed, which resetForm()s away both
    // the 422 message and everything the user typed (see TransactionsView's note —
    // the same bug, one component over).
    drawerVisible.value = false
    toast.add({
      severity: 'success',
      summary: target ? 'Cash movement updated' : 'Cash movement added',
      // The server's post-write balance, quoted rather than recomputed client-side.
      detail: `${cashKindLabel(values.kind)} of ${formatCurrency(values.amount)} — cash is now ${formatCurrency(response.meta.cash_balance)}`,
      life: 5000,
    })
  } catch (error) {
    drawer.value?.applyServerError(error)
  }
}

// --- Delete ------------------------------------------------------------------

const confirmVisible = shallowRef(false)
const deletingCash = shallowRef<CashTransaction | null>(null)
const deleteError = shallowRef<string | null>(null)
const deletePending = computed(() => deleteMutation.isLoading.value)

function askDelete(cashTransaction: CashTransaction): void {
  deletingCash.value = cashTransaction
  deleteError.value = null
  confirmVisible.value = true
}

const deleteMessage = computed(() => {
  const target = deletingCash.value
  if (!target) return ''
  return `Delete the ${cashKindLabel(target.kind).toLowerCase()} of ${formatCurrency(target.amount)} on ${target.occurred_on}? This can’t be undone.`
})

async function confirmDelete(): Promise<void> {
  const target = deletingCash.value
  if (!target) return
  deleteError.value = null
  try {
    await deleteMutation.mutateAsync(target.id)
    confirmVisible.value = false
  } catch (error) {
    deleteError.value = mapApiError(error, []).formMessage ?? 'Could not delete the cash movement.'
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
  <section aria-label="Cash" class="mb-8">
    <header class="mb-3 flex flex-wrap items-start justify-between gap-3">
      <div>
        <h2 class="text-base font-semibold text-ink">Cash</h2>
        <p class="mt-0.5 text-sm text-ink-muted">
          Deposits and withdrawals. Recording them makes this portfolio’s total match your
          broker’s, and measures your return against the money you actually put in.
        </p>
      </div>
      <Button label="Add cash movement" :pt="buttonPt" @click="openCreate" />
    </header>

    <AdvisoryNotice :message="negativeNotice" tone="warn" class="mb-3" />

    <!-- Loading -->
    <div
      v-if="status === 'pending'"
      class="h-32 animate-pulse rounded-lg border border-line bg-panel"
      aria-hidden="true"
    />
    <span v-if="status === 'pending'" class="sr-only">Loading cash movements…</span>

    <!-- Error -->
    <div
      v-else-if="status === 'error'"
      class="rounded-lg border border-line bg-panel p-6 text-center"
    >
      <p class="text-sm text-ink">We couldn’t load this portfolio’s cash.</p>
      <Button
        label="Retry"
        severity="secondary"
        class="mt-3"
        :pt="buttonPt"
        @click="() => refetch()"
      />
    </div>

    <!-- Empty -->
    <div
      v-else-if="isEmpty"
      class="rounded-lg border border-dashed border-line-strong bg-panel p-6 text-center"
    >
      <p class="text-sm text-ink">No cash recorded yet</p>
      <p class="mx-auto mt-1 max-w-md text-sm text-ink-muted">
        Until a deposit is recorded, returns are measured against what you paid for your
        holdings rather than against the money you put in.
      </p>
      <Button label="Add cash movement" class="mt-4" :pt="buttonPt" @click="openCreate" />
    </div>

    <!-- List -->
    <div v-else class="overflow-hidden rounded-lg border border-line bg-panel">
      <CashTable :cash-transactions="cashTransactions" @edit="openEdit" @delete="askDelete" />
      <Paginator
        v-if="showPaginator"
        :rows="perPage"
        :total-records="totalRecords"
        :first="firstRecord"
        :pt="paginatorPt"
        @page="onPageChange"
      />
    </div>

    <CashFormDrawer
      ref="drawer"
      v-model:visible="drawerVisible"
      :cash-transaction="editingCash"
      :cash-balance="cashBalance"
      :busy="isSaving"
      @submit="onSubmit"
    />

    <ConfirmDialog
      v-model:visible="confirmVisible"
      title="Delete cash movement"
      :message="deleteMessage"
      confirm-label="Delete"
      danger
      :pending="deletePending"
      :error="deleteError"
      @confirm="confirmDelete"
    />
  </section>
</template>
