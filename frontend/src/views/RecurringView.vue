<script setup lang="ts">
import { computed, shallowRef, useTemplateRef } from 'vue'
import Button from 'primevue/button'
import { useToast } from 'primevue/usetoast'
import RecurringRuleCard from '@/components/recurring/RecurringRuleCard.vue'
import RecurringFormDrawer from '@/components/recurring/RecurringFormDrawer.vue'
import ConfirmDialog from '@/components/ui/ConfirmDialog.vue'
import {
  useRecurringQuery,
  useCreateRecurring,
  useUpdateRecurring,
  useDeleteRecurring,
} from '@/composables/useRecurringTransactions'
import { toRecurringInput, type RecurringFormValues } from '@/forms/recurring'
import { mapApiError } from '@/lib/formErrors'
import { buttonPt } from '@/primevue/pt'
import type { RecurringTransaction } from '@/types'

/**
 * Recurring-transactions page (#50): the rule list, the create/edit drawer with
 * its NextRunPreview, pause/resume, and delete.
 */
const props = defineProps<{ id: string }>()
const portfolioId = computed(() => Number(props.id))

const { rules, status, isEmpty, refetch } = useRecurringQuery(portfolioId)

const createMutation = useCreateRecurring(portfolioId)
const updateMutation = useUpdateRecurring(portfolioId)
const deleteMutation = useDeleteRecurring(portfolioId)

const toast = useToast()

// --- Create / edit -----------------------------------------------------------

const drawerVisible = shallowRef(false)
const editingRule = shallowRef<RecurringTransaction | null>(null)
const drawer = useTemplateRef<{ applyServerError: (error: unknown) => void }>('drawer')

const isSaving = computed(() => createMutation.isLoading.value || updateMutation.isLoading.value)

function openCreate(): void {
  editingRule.value = null
  drawerVisible.value = true
}

function openEdit(rule: RecurringTransaction): void {
  editingRule.value = rule
  drawerVisible.value = true
}

async function onSubmit(values: RecurringFormValues): Promise<void> {
  const target = editingRule.value
  const input = toRecurringInput(values)

  try {
    if (target) {
      await updateMutation.mutateAsync({ id: target.id, input })
    } else {
      await createMutation.mutateAsync(input)
    }
    drawerVisible.value = false
    toast.add({
      severity: 'success',
      summary: target ? 'Rule updated' : 'Rule created',
      detail: `${values.symbol} · ${values.frequency}`,
      life: 4000,
    })
  } catch (error) {
    // Keeps the drawer open with the user's input and maps the 422 onto fields —
    // e.g. an unknown or non-US ticker lands on `symbol`.
    drawer.value?.applyServerError(error)
  }
}

// --- Pause / resume ----------------------------------------------------------

/** id of the rule currently being toggled, so only its card disables. */
const togglingId = shallowRef<number | null>(null)

async function onToggle(rule: RecurringTransaction): Promise<void> {
  togglingId.value = rule.id
  const resuming = !rule.active
  try {
    // PATCH { active } alone: the controller clears paused_reason and the skip
    // counter on reactivation, so a system-paused rule resumes cleanly.
    await updateMutation.mutateAsync({ id: rule.id, input: { active: resuming } })
    toast.add({
      severity: 'success',
      summary: resuming ? 'Rule resumed' : 'Rule paused',
      detail: rule.symbol,
      life: 3000,
    })
  } catch (error) {
    toast.add({
      severity: 'error',
      summary: resuming ? 'Could not resume the rule' : 'Could not pause the rule',
      detail: mapApiError(error, []).formMessage ?? undefined,
      life: 6000,
    })
  } finally {
    togglingId.value = null
  }
}

// --- Delete ------------------------------------------------------------------

const confirmVisible = shallowRef(false)
const deletingRule = shallowRef<RecurringTransaction | null>(null)
const deleteError = shallowRef<string | null>(null)
const deletePending = computed(() => deleteMutation.isLoading.value)

function askDelete(rule: RecurringTransaction): void {
  deletingRule.value = rule
  deleteError.value = null
  confirmVisible.value = true
}

const deleteMessage = computed(() => {
  const target = deletingRule.value
  if (!target) return ''
  // Worth stating plainly: deleting the rule does NOT unwind the buys it already
  // made (the FK is ON DELETE SET NULL), so history is preserved.
  return `Delete the recurring buy of ${target.symbol}? Transactions it already created are kept — only future runs stop.`
})

async function confirmDelete(): Promise<void> {
  const target = deletingRule.value
  if (!target) return
  deleteError.value = null
  try {
    await deleteMutation.mutateAsync(target.id)
    confirmVisible.value = false
  } catch (error) {
    deleteError.value = mapApiError(error, []).formMessage ?? 'Could not delete the rule.'
  }
}
</script>

<template>
  <section>
    <header class="mb-6 flex flex-wrap items-start justify-between gap-4">
      <div>
        <h1 class="text-xl font-semibold tracking-tight text-ink">Recurring buys</h1>
        <p class="mt-1 text-sm text-ink-muted">
          Scheduled purchases for this portfolio. Sells stay manual.
        </p>
      </div>
      <Button label="New recurring buy" :pt="buttonPt" @click="openCreate" />
    </header>

    <!-- Loading -->
    <div v-if="status === 'pending'" class="grid gap-4 sm:grid-cols-2">
      <div
        v-for="n in 2"
        :key="n"
        class="h-40 animate-pulse rounded-lg border border-line bg-panel"
        aria-hidden="true"
      />
      <span class="sr-only">Loading recurring buys…</span>
    </div>

    <!-- Error -->
    <div
      v-else-if="status === 'error'"
      class="rounded-lg border border-line bg-panel p-8 text-center"
    >
      <p class="text-sm text-ink">We couldn’t load your recurring buys.</p>
      <p class="mt-1 text-sm text-ink-muted">Check your connection and try again.</p>
      <Button
        label="Retry"
        severity="secondary"
        class="mt-4"
        :pt="buttonPt"
        @click="() => refetch()"
      />
    </div>

    <!-- Empty -->
    <div
      v-else-if="isEmpty"
      class="rounded-lg border border-dashed border-line-strong bg-panel p-10 text-center"
    >
      <h2 class="text-base font-semibold text-ink">No recurring buys yet</h2>
      <p class="mx-auto mt-1 max-w-sm text-sm text-ink-muted">
        Set up a schedule to invest a fixed amount — or a fixed number of shares — automatically.
      </p>
      <Button label="New recurring buy" class="mt-5" :pt="buttonPt" @click="openCreate" />
    </div>

    <!-- List -->
    <div v-else class="grid gap-4 sm:grid-cols-2">
      <RecurringRuleCard
        v-for="rule in rules"
        :key="rule.id"
        :rule="rule"
        :busy="togglingId === rule.id"
        @edit="openEdit"
        @toggle="onToggle"
        @delete="askDelete"
      />
    </div>

    <RecurringFormDrawer
      ref="drawer"
      v-model:visible="drawerVisible"
      :portfolio-id="portfolioId"
      :rule="editingRule"
      :busy="isSaving"
      @submit="onSubmit"
    />

    <ConfirmDialog
      v-model:visible="confirmVisible"
      title="Delete recurring buy"
      :message="deleteMessage"
      confirm-label="Delete"
      danger
      :pending="deletePending"
      :error="deleteError"
      @confirm="confirmDelete"
    />
  </section>
</template>
