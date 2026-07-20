<script setup lang="ts">
import { computed, shallowRef } from 'vue'
import Button from 'primevue/button'
import PortfolioCard from '@/components/portfolios/PortfolioCard.vue'
import PortfolioFormDialog from '@/components/portfolios/PortfolioFormDialog.vue'
import ConfirmDialog from '@/components/ui/ConfirmDialog.vue'
import { usePortfoliosQuery, useDeletePortfolio } from '@/composables/usePortfolios'
import { useBenchmarksQuery, benchmarkLabel } from '@/composables/useBenchmarks'
import { mapApiError } from '@/lib/formErrors'
import { buttonPt } from '@/primevue/pt'
import type { Portfolio } from '@/types'

const { portfolios, status, isEmpty, refetch } = usePortfoliosQuery()
const { benchmarks } = useBenchmarksQuery()

const benchmarkNames = computed(() => {
  const map = new Map<number, string>()
  for (const b of benchmarks.value) map.set(b.id, benchmarkLabel(b))
  return map
})
function labelFor(portfolio: Portfolio): string {
  if (portfolio.benchmark_id === null) return 'No benchmark'
  return benchmarkNames.value.get(portfolio.benchmark_id) ?? 'Benchmark'
}

// --- Create / edit ---
const dialogVisible = shallowRef(false)
const editingPortfolio = shallowRef<Portfolio | null>(null)
function openCreate() {
  editingPortfolio.value = null
  dialogVisible.value = true
}
function openEdit(portfolio: Portfolio) {
  editingPortfolio.value = portfolio
  dialogVisible.value = true
}

// --- Delete ---
const deleteMutation = useDeletePortfolio()
const confirmVisible = shallowRef(false)
const deletingPortfolio = shallowRef<Portfolio | null>(null)
const deleteError = shallowRef<string | null>(null)
const deletePending = computed(() => deleteMutation.isLoading.value)

function askDelete(portfolio: Portfolio) {
  deletingPortfolio.value = portfolio
  deleteError.value = null
  confirmVisible.value = true
}
const deleteMessage = computed(() =>
  deletingPortfolio.value
    ? `Delete “${deletingPortfolio.value.name}”? This also removes its transactions and recurring rules, and can’t be undone.`
    : '',
)
async function confirmDelete() {
  const target = deletingPortfolio.value
  if (!target) return
  deleteError.value = null
  try {
    await deleteMutation.mutateAsync(target.id)
    confirmVisible.value = false
  } catch (err) {
    deleteError.value = mapApiError(err, []).formMessage ?? 'Could not delete the portfolio.'
  }
}
</script>

<template>
  <section>
    <header class="mb-6 flex items-start justify-between gap-4">
      <div>
        <h1 class="text-xl font-semibold tracking-tight text-ink">Portfolios</h1>
        <p class="mt-1 text-sm text-ink-muted">Your portfolios, with value sparklines.</p>
      </div>
      <Button label="New portfolio" :pt="buttonPt" @click="openCreate" />
    </header>

    <!-- Loading -->
    <div v-if="status === 'pending'" class="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
      <div
        v-for="n in 3"
        :key="n"
        class="h-44 animate-pulse rounded-lg border border-line bg-panel"
        aria-hidden="true"
      />
      <span class="sr-only">Loading portfolios…</span>
    </div>

    <!-- Error -->
    <div
      v-else-if="status === 'error'"
      class="rounded-lg border border-line bg-panel p-8 text-center"
    >
      <p class="text-sm text-ink">We couldn’t load your portfolios.</p>
      <p class="mt-1 text-sm text-ink-muted">Check your connection and try again.</p>
      <Button label="Retry" severity="secondary" class="mt-4" :pt="buttonPt" @click="() => refetch()" />
    </div>

    <!-- Empty -->
    <div
      v-else-if="isEmpty"
      class="rounded-lg border border-dashed border-line-strong bg-panel p-10 text-center"
    >
      <h2 class="text-base font-semibold text-ink">No portfolios yet</h2>
      <p class="mx-auto mt-1 max-w-sm text-sm text-ink-muted">
        Create your first portfolio to start tracking holdings, transactions, and performance.
      </p>
      <Button label="New portfolio" class="mt-5" :pt="buttonPt" @click="openCreate" />
    </div>

    <!-- List -->
    <div v-else class="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
      <PortfolioCard
        v-for="portfolio in portfolios"
        :key="portfolio.id"
        :portfolio="portfolio"
        :benchmark-label="labelFor(portfolio)"
        @edit="openEdit"
        @delete="askDelete"
      />
    </div>

    <PortfolioFormDialog v-model:visible="dialogVisible" :portfolio="editingPortfolio" />

    <ConfirmDialog
      v-model:visible="confirmVisible"
      title="Delete portfolio"
      :message="deleteMessage"
      confirm-label="Delete"
      danger
      :pending="deletePending"
      :error="deleteError"
      @confirm="confirmDelete"
    />
  </section>
</template>
