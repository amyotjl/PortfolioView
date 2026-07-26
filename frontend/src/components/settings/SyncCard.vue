<script setup lang="ts">
import { computed, shallowRef } from 'vue'
import Button from 'primevue/button'
import Tag from 'primevue/tag'
import { useToast } from 'primevue/usetoast'
import FormAlert from '@/components/ui/FormAlert.vue'
import { useSyncStatusQuery, useTriggerSync } from '@/composables/useSync'
import {
  alreadyRequestedMessage,
  freshnessHint,
  freshnessSeverity,
  triggerFailureToast,
  triggerToast,
} from '@/lib/syncStatus'
import { mapApiError } from '@/lib/formErrors'
import { buttonPt, tagPt } from '@/primevue/pt'

/**
 * Settings › Price data (issue #57): the manual "Sync now" trigger plus the
 * freshness hint that tells the user whether pressing it is worth anything.
 *
 * Lives in its own component so SettingsView stays a composition surface, and
 * every string it renders comes from the pure helpers in `lib/syncStatus.ts`.
 */

const { sync, status: snapshotStatus, refetch } = useSyncStatusQuery()
const trigger = useTriggerSync()
const toast = useToast()

/** Last trigger failure, kept on the page so the message survives the toast. */
const failure = shallowRef<string | null>(null)

const hint = computed(() => (sync.value ? freshnessHint(sync.value) : null))

/**
 * The pending notice is driven by the SNAPSHOT, so a sync claimed by cron, the
 * boot catch-up, or another tab is visible on page load — not only after a click.
 */
const pendingNotice = computed(() =>
  sync.value?.pending ? alreadyRequestedMessage(sync.value.requested_at) : null,
)

/**
 * In-flight = our own POST is running, or the server says the 10-minute lease is
 * held. Clicking again in either case can only ever return `already_pending`, so
 * the button disables — and "Check again" is offered alongside it, because the
 * lease outlives the actual work and nothing releases it early.
 */
const isBusy = computed(() => trigger.isLoading.value || sync.value?.pending === true)
const buttonLabel = computed(() => (isBusy.value ? 'Syncing…' : 'Sync now'))

async function syncNow(): Promise<void> {
  failure.value = null
  try {
    // Both `enqueued` and `already_pending` arrive here — they are 202s, and the
    // deduped one is informational, never a failure toast.
    toast.add({ ...triggerToast(await trigger.mutateAsync()), life: 5000 })
  } catch (error) {
    // 401 has already been routed to /login by the fetch client; 403/5xx and a
    // dead connection land here with the envelope's own message.
    const message = mapApiError(error, []).formMessage
    failure.value = triggerFailureToast(message).detail
    toast.add({ ...triggerFailureToast(message), life: 6000 })
  }
}
</script>

<template>
  <section class="max-w-xl rounded-lg border border-line bg-panel p-6">
    <h2 class="text-sm font-semibold text-ink">Price data</h2>
    <p class="mt-1 text-sm text-ink-muted">
      Prices refresh automatically every night. Sync manually if this machine was asleep when the
      nightly run was due.
    </p>

    <!-- Freshness hint. role="status" so a screen reader hears it change. -->
    <div class="mt-4 min-h-6" role="status">
      <div v-if="snapshotStatus === 'pending'" class="h-5 w-64 animate-pulse rounded bg-panel-hi">
        <span class="sr-only">Checking price freshness…</span>
      </div>

      <p v-else-if="snapshotStatus === 'error'" class="text-sm text-ink-muted">
        Couldn’t check when prices were last updated. You can still start a sync.
      </p>

      <div v-else-if="hint" class="flex flex-wrap items-center gap-2">
        <Tag :value="hint.label" :severity="freshnessSeverity(hint.tone)" :pt="tagPt" />
        <span class="text-sm tabular-nums text-ink">{{ hint.text }}</span>
      </div>
    </div>

    <p v-if="pendingNotice" class="mt-2 text-sm tabular-nums text-ink-muted">
      {{ pendingNotice }}
    </p>

    <FormAlert v-if="failure" :message="failure" class="mt-4" />

    <div class="mt-5 flex flex-wrap items-center gap-2">
      <Button
        :label="buttonLabel"
        :loading="isBusy"
        :aria-busy="isBusy"
        :pt="buttonPt"
        @click="syncNow"
      >
        <!-- Unstyled PrimeVue ships no spinner CSS, so the in-flight indicator is
             ours. aria-hidden: the state is already carried by the label + aria-busy. -->
        <template #loadingicon>
          <span
            class="h-4 w-4 shrink-0 animate-spin rounded-full border-2 border-current border-t-transparent"
            aria-hidden="true"
          />
        </template>
      </Button>

      <Button
        label="Check again"
        text
        :pt="buttonPt"
        @click="() => refetch()"
      />
    </div>
  </section>
</template>
