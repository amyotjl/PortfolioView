<script setup lang="ts">
import { computed, shallowRef, watch } from 'vue'
import Dialog from 'primevue/dialog'
import Select from 'primevue/select'
import Button from 'primevue/button'
import FormAlert from '@/components/ui/FormAlert.vue'
import ImportReportPanel from '@/components/portfolios/ImportReportPanel.vue'
import { useImportPortfolios } from '@/composables/usePortfolioTransfer'
import { mapApiError } from '@/lib/formErrors'
import { buttonPt, dialogPt, selectPt } from '@/primevue/pt'
import { MAX_IMPORT_BYTES, type ImportReport, type OnConflictMode } from '@/types'

/**
 * Upload a PortfolioView export, a broker activity ledger, or a broker holdings
 * report (issues #64, #68). The format is sniffed from file CONTENT by the
 * backend's Detector, so the copy here names the three formats but the input
 * accepts any .json/.csv and lets the server decide.
 *
 * A plain <input type="file"> rather than PrimeVue's FileUpload: in unstyled mode
 * FileUpload brings a whole upload lifecycle (its own XHR, progress, chunking)
 * that would bypass this app's fetch client — and with it the CSRF header, the
 * 401 handler and the error envelope. One native input plus the existing client
 * is both smaller and correct.
 *
 * PREVIEW FIRST is the default posture: the server can run the entire import and
 * roll it back, so the user can see every rename and failure before committing.
 */
const visible = defineModel<boolean>('visible', { required: true })
const emit = defineEmits<{ imported: [] }>()

const importMutation = useImportPortfolios()

const file = shallowRef<File | null>(null)
const onConflict = shallowRef<OnConflictMode>('rename')
const report = shallowRef<ImportReport | null>(null)
const formError = shallowRef<string | null>(null)
const fileInput = shallowRef<HTMLInputElement | null>(null)

const pending = computed(() => importMutation.isLoading.value)
/** A committed (non-preview) run: the dialog switches to a done state. */
const committed = computed(() => report.value !== null && !report.value.dry_run)

const conflictOptions = [
  { label: 'Rename the incoming portfolio', value: 'rename' },
  { label: 'Skip it and keep mine', value: 'skip' },
]

function reset() {
  file.value = null
  report.value = null
  formError.value = null
  onConflict.value = 'rename'
  if (fileInput.value) fileInput.value.value = ''
}

watch(visible, (open) => {
  if (open) reset()
})

function onFileChange(event: Event) {
  const picked = (event.target as HTMLInputElement).files?.[0] ?? null
  formError.value = null
  // A new file invalidates the previous run's report.
  report.value = null

  if (picked && picked.size > MAX_IMPORT_BYTES) {
    // Refuse locally rather than spending an 8 MB upload to be told the same
    // thing; the server enforces the identical cap regardless.
    file.value = null
    formError.value = `That file is ${(picked.size / (1024 * 1024)).toFixed(1)} MB. The limit is ${MAX_IMPORT_BYTES / (1024 * 1024)} MB.`
    return
  }
  file.value = picked
}

async function run(dryRun: boolean) {
  if (!file.value) {
    formError.value = 'Choose a file to import.'
    return
  }
  formError.value = null
  try {
    report.value = await importMutation.mutateAsync({
      file: file.value,
      onConflict: onConflict.value,
      dryRun,
    })
    if (!dryRun) emit('imported')
  } catch (err) {
    report.value = null
    const mapped = mapApiError(err, ['file'])
    const fileMessage = mapped.fieldErrors.file
    // The server's `file` messages follow the Rails field-message convention
    // ("is required", "must be smaller than 8 MB", "is not valid JSON…") — they
    // are FRAGMENTS meant to be prefixed by the field name. This form has one
    // field, so the message is shown as a banner; prefix it or it reads as a
    // sentence with its subject missing.
    formError.value = fileMessage
      ? `File ${fileMessage}`
      : (mapped.formMessage ?? 'The file could not be imported.')
  }
}
</script>

<template>
  <Dialog
    v-model:visible="visible"
    modal
    header="Import portfolios"
    :draggable="false"
    :dismissable-mask="!pending"
    :closable="!pending"
    :pt="{ ...dialogPt, root: 'w-full max-w-2xl rounded-lg border border-line bg-panel shadow-2xl' }"
  >
    <div class="flex flex-col gap-4">
      <FormAlert :message="formError" />

      <template v-if="!committed">
        <p class="text-sm text-ink-muted">
          Upload a PortfolioView export (<code class="text-xs">.json</code>), a broker activity
          ledger, or a broker holdings report (<code class="text-xs">.csv</code>). If you have both
          broker files, prefer the activity ledger — it carries real trade dates. Nothing you
          already have is overwritten.
        </p>

        <div class="flex flex-col gap-1.5">
          <label for="import-file" class="text-sm font-medium text-ink">File</label>
          <input
            id="import-file"
            ref="fileInput"
            type="file"
            accept=".json,.csv,application/json,text/csv"
            :disabled="pending"
            class="w-full cursor-pointer rounded-md border border-line bg-panel px-3 py-2 text-sm text-ink outline-none transition-colors file:mr-3 file:cursor-pointer file:rounded file:border-0 file:bg-panel-hi file:px-3 file:py-1.5 file:text-sm file:font-medium file:text-ink hover:border-accent focus:ring-2 focus:ring-accent-soft disabled:cursor-not-allowed disabled:opacity-60"
            @change="onFileChange"
          />
        </div>

        <div class="flex flex-col gap-1.5">
          <label id="import-conflict-label" class="text-sm font-medium text-ink">
            If a portfolio name already exists
          </label>
          <Select
            v-model="onConflict"
            :options="conflictOptions"
            option-label="label"
            option-value="value"
            :disabled="pending"
            class="w-full"
            aria-labelledby="import-conflict-label"
            :pt="selectPt"
          />
        </div>
      </template>

      <ImportReportPanel v-if="report" :report="report" />
    </div>

    <template #footer>
      <!-- "Done", not "Close": the header's X button already carries the
           accessible name "Close", and two controls with one name is both an a11y
           smell and ambiguous to address in tests. -->
      <Button
        :label="committed ? 'Done' : 'Cancel'"
        severity="secondary"
        :disabled="pending"
        :pt="buttonPt"
        @click="visible = false"
      />
      <template v-if="!committed">
        <Button
          :label="pending ? 'Checking…' : 'Preview'"
          severity="secondary"
          :disabled="pending || !file"
          :pt="buttonPt"
          @click="run(true)"
        />
        <Button
          :label="pending ? 'Importing…' : 'Import'"
          :disabled="pending || !file"
          :pt="buttonPt"
          @click="run(false)"
        />
      </template>
    </template>
  </Dialog>
</template>
