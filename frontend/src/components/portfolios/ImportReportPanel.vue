<script setup lang="ts">
import { computed } from 'vue'
import Tag from 'primevue/tag'
import { tagPt } from '@/primevue/pt'
import { allWarnings, hasFailures, statusLabel, statusSeverity, summaryLine } from '@/lib/importSummary'
import { formatLabel, type ImportReport } from '@/types'

/**
 * The outcome of one import run (issue #64).
 *
 * An import is a bulk mutation the user could not inspect beforehand, so this
 * panel is the ONLY place they learn what actually happened — a rename, a dropped
 * benchmark, a skipped short position, a venue-suffixed ticker. Nothing here is
 * collapsed to a bare count, and failures are stated before successes.
 */
const props = defineProps<{ report: ImportReport }>()

const failed = computed(() => hasFailures(props.report))
const summary = computed(() => summaryLine(props.report))
const warnings = computed(() => allWarnings(props.report))
const failures = computed(() => props.report.portfolios.filter((p) => p.errors.length > 0))
</script>

<template>
  <section class="flex flex-col gap-4" aria-live="polite">
    <!-- Headline -->
    <div
      class="rounded-md border px-3 py-2.5"
      :class="failed ? 'border-down/30 bg-down/10' : 'border-line bg-panel-hi'"
    >
      <p class="text-sm font-medium" :class="failed ? 'text-down' : 'text-ink'">
        {{ summary }}
      </p>
      <p class="mt-1 text-xs text-ink-muted">
        Detected format: {{ formatLabel(report.format) }}<span v-if="report.dry_run"> · preview only, nothing was saved</span>
      </p>
    </div>

    <!-- Per-portfolio outcomes -->
    <div v-if="report.portfolios.length > 0" class="overflow-x-auto">
      <table class="w-full border-collapse text-sm">
        <thead class="border-b border-line">
          <tr>
            <th scope="col" class="px-2 py-2 text-left text-xs font-semibold uppercase tracking-wide text-ink-subtle">
              Portfolio
            </th>
            <th scope="col" class="px-2 py-2 text-left text-xs font-semibold uppercase tracking-wide text-ink-subtle">
              Outcome
            </th>
            <th scope="col" class="px-2 py-2 text-right text-xs font-semibold uppercase tracking-wide text-ink-subtle">
              Transactions
            </th>
            <th scope="col" class="px-2 py-2 text-right text-xs font-semibold uppercase tracking-wide text-ink-subtle">
              Rules
            </th>
          </tr>
        </thead>
        <tbody>
          <tr
            v-for="(portfolio, index) in report.portfolios"
            :key="`${portfolio.name}-${index}`"
            class="border-b border-line/60"
          >
            <td class="px-2 py-2 align-top text-ink">
              <span class="font-medium">{{ portfolio.name }}</span>
              <!-- The rename is the single most surprising outcome, so it is shown
                   inline on the row rather than only in the warnings list. -->
              <span
                v-if="portfolio.imported_as && portfolio.imported_as !== portfolio.name"
                class="block text-xs text-ink-muted"
              >
                imported as “{{ portfolio.imported_as }}”
              </span>
            </td>
            <td class="px-2 py-2 align-top">
              <Tag
                :value="statusLabel(portfolio.status)"
                :severity="statusSeverity(portfolio.status)"
                :pt="tagPt"
              />
            </td>
            <td class="px-2 py-2 text-right align-top tabular-nums text-ink">
              {{ portfolio.transactions_created }}
            </td>
            <td class="px-2 py-2 text-right align-top tabular-nums text-ink">
              {{ portfolio.recurring_created }}
            </td>
          </tr>
        </tbody>
      </table>
    </div>

    <!-- Failures, with the server's own reason -->
    <div v-if="failures.length > 0" class="flex flex-col gap-2">
      <h3 class="text-xs font-semibold uppercase tracking-wide text-ink-subtle">Why these failed</h3>
      <ul class="flex flex-col gap-1.5">
        <li
          v-for="portfolio in failures"
          :key="`fail-${portfolio.name}`"
          class="rounded-md border border-down/30 bg-down/10 px-3 py-2 text-sm text-down"
        >
          <span class="font-medium">{{ portfolio.name }}:</span>
          {{ portfolio.errors.join(' ') }}
        </li>
      </ul>
      <p class="text-xs text-ink-muted">
        A portfolio that fails is rolled back completely — none of its transactions were saved, so you
        can fix the file and import it again.
      </p>
    </div>

    <!-- Warnings -->
    <details v-if="warnings.length > 0" class="rounded-md border border-line bg-panel-hi" open>
      <summary class="cursor-pointer px-3 py-2 text-xs font-semibold uppercase tracking-wide text-ink-subtle">
        {{ warnings.length }} note{{ warnings.length === 1 ? '' : 's' }} about this import
      </summary>
      <ul class="flex flex-col gap-1.5 border-t border-line px-3 py-2.5">
        <li v-for="(warning, index) in warnings" :key="index" class="text-sm text-ink-muted">
          <span v-if="warning.scope" class="font-medium text-ink">{{ warning.scope }}: </span>
          {{ warning.message }}
        </li>
      </ul>
    </details>
  </section>
</template>
