<script setup lang="ts">
import { computed, shallowRef, watch } from 'vue'
import { useForm } from 'vee-validate'
import { toTypedSchema } from '@vee-validate/zod'
import Drawer from 'primevue/drawer'
import AutoComplete from 'primevue/autocomplete'
import DatePicker from 'primevue/datepicker'
import InputText from 'primevue/inputtext'
import Select from 'primevue/select'
import SelectButton from 'primevue/selectbutton'
import Button from 'primevue/button'
import FormField from '@/components/ui/FormField.vue'
import FormAlert from '@/components/ui/FormAlert.vue'
import NextRunPreview from '@/components/recurring/NextRunPreview.vue'
import { useInstrumentSearch, instrumentLabel } from '@/composables/useInstrumentForm'
import { useRecurringPreview } from '@/composables/useRecurringTransactions'
import {
  recurringFormSchema,
  emptyRecurringForm,
  RECURRING_FORM_FIELDS,
  type RecurringFormValues,
} from '@/forms/recurring'
import { mapApiError } from '@/lib/formErrors'
import { isoToPickerDate, pickerDateToIso, todayIso } from '@/lib/tradingDays'
import {
  autoCompletePt,
  buttonPt,
  datePickerPt,
  drawerPt,
  inputTextPt,
  selectPt,
  selectButtonPt,
} from '@/primevue/pt'
import type { InstrumentSearchResult, RecurringTransaction } from '@/types'

/**
 * Create (rule = null) or edit (rule set) drawer for a recurring buy.
 *
 * Like the transaction drawer, it owns the form but not the mutation: the parent
 * submits and reports failures back through `applyServerError`.
 *
 * v1 is BUY-ONLY (the server 422s a sell rule), so there is no side control.
 */
const visible = defineModel<boolean>('visible', { required: true })

const props = defineProps<{
  portfolioId: number
  rule?: RecurringTransaction | null
  busy?: boolean
}>()

const emit = defineEmits<{ submit: [values: RecurringFormValues] }>()

const isEdit = computed(() => Boolean(props.rule))
const title = computed(() => (isEdit.value ? 'Edit recurring buy' : 'New recurring buy'))

const AMOUNT_MODES = [
  { label: 'Dollar amount', value: 'dollars' },
  { label: 'Share count', value: 'shares' },
] as const

const FREQUENCY_OPTIONS = [
  { label: 'Weekly', value: 'weekly' },
  { label: 'Every 2 weeks', value: 'biweekly' },
  { label: 'Monthly', value: 'monthly' },
  { label: 'Quarterly', value: 'quarterly' },
] as const

const { results: symbolResults, search } = useInstrumentSearch()
const { runDates, isLoading: isPreviewLoading, preview } = useRecurringPreview(
  () => props.portfolioId,
)

const formError = shallowRef<string | null>(null)

const { defineField, handleSubmit, errors, setErrors, resetForm, values } =
  useForm<RecurringFormValues>({
    validationSchema: toTypedSchema(recurringFormSchema),
    initialValues: emptyRecurringForm(todayIso()),
  })

const [symbol] = defineField('symbol')
const [amountType] = defineField('amount_type')
const [dollarAmount, dollarAttrs] = defineField('dollar_amount')
const [shareAmount, shareAttrs] = defineField('share_amount')
const [frequency] = defineField('frequency')
const [anchorOn] = defineField('anchor_on')
const [endOn] = defineField('end_on')

const isDollars = computed(() => values.amount_type === 'dollars')

const anchorDate = computed<Date | null>({
  get: () => isoToPickerDate(anchorOn.value),
  set: (date) => {
    const iso = pickerDateToIso(date)
    if (iso) anchorOn.value = iso
  },
})

// End date is optional, so clearing the picker must clear the value, not be
// ignored the way an unset anchor is.
const endDate = computed<Date | null>({
  get: () => isoToPickerDate(endOn.value),
  set: (date) => {
    endOn.value = pickerDateToIso(date)
  },
})

watch(visible, (open) => {
  if (!open) return
  formError.value = null
  symbolResults.value = []
  runDates.value = []

  resetForm({
    values: props.rule
      ? {
          symbol: props.rule.symbol,
          amount_type: props.rule.amount_type,
          dollar_amount: props.rule.dollar_amount,
          share_amount: props.rule.share_amount,
          frequency: props.rule.frequency,
          anchor_on: props.rule.anchor_on,
          end_on: props.rule.end_on,
          active: props.rule.active,
        }
      : emptyRecurringForm(todayIso()),
  })
})

/**
 * Live-update the preview as frequency or anchor changes (#50 AC). Runs while the
 * drawer is open, including on the initial seed, so an edit form shows its
 * schedule immediately.
 */
watch(
  () => [values.frequency, values.anchor_on] as const,
  ([nextFrequency, nextAnchor]) => {
    if (!visible.value) return
    void preview(nextFrequency, nextAnchor)
  },
  { immediate: true },
)

const onSubmit = handleSubmit((formValues) => {
  formError.value = null
  emit('submit', formValues)
})

function applyServerError(error: unknown): void {
  const mapped = mapApiError(error, RECURRING_FORM_FIELDS)
  if (Object.keys(mapped.fieldErrors).length > 0) setErrors(mapped.fieldErrors)
  formError.value = mapped.formMessage
}

defineExpose({ applyServerError })

function onSymbolComplete(event: { query: string }): void {
  void search(event.query)
}

function onSymbolSelect(event: { value: InstrumentSearchResult }): void {
  symbol.value = event.value.symbol
}
</script>

<template>
  <Drawer
    v-model:visible="visible"
    position="right"
    :header="title"
    :dismissable-mask="!props.busy"
    :closable="!props.busy"
    :pt="drawerPt"
  >
    <form id="recurring-form" class="flex flex-col gap-4" novalidate @submit.prevent="onSubmit">
      <FormAlert :message="formError" />

      <p class="rounded-md border border-line bg-panel-hi px-3 py-2 text-sm text-ink-muted">
        Recurring rules buy only. Sells stay manual in this version.
      </p>

      <FormField
        label="Ticker"
        :error="errors.symbol"
        required
        hint="Search the local directory — no API quota is used."
      >
        <template #default="{ id, invalid, describedby }">
          <AutoComplete
            :input-id="id"
            v-model="symbol"
            :suggestions="symbolResults"
            option-label="symbol"
            force-selection
            complete-on-focus
            :delay="250"
            placeholder="e.g. VTI"
            :invalid="invalid"
            :aria-describedby="describedby"
            :pt="autoCompletePt"
            @complete="onSymbolComplete"
            @item-select="onSymbolSelect"
          >
            <template #option="{ option }">
              <span class="font-medium text-ink">{{ option.symbol }}</span>
              <span v-if="instrumentLabel(option) !== option.symbol" class="ml-2 text-ink-subtle">
                {{ instrumentLabel(option).replace(`${option.symbol} — `, '') }}
              </span>
            </template>
          </AutoComplete>
        </template>
      </FormField>

      <FormField label="Invest by" :error="errors.amount_type">
        <template #default="{ id }">
          <SelectButton
            :input-id="id"
            v-model="amountType"
            :options="[...AMOUNT_MODES]"
            option-label="label"
            option-value="value"
            :allow-empty="false"
            :pt="selectButtonPt"
          />
        </template>
      </FormField>

      <!--
        Only the active mode's field renders, so the hidden one can never hold a
        stale value or a stale error (the schema requires whichever mode is on).
      -->
      <FormField
        v-if="isDollars"
        label="Amount per run"
        :error="errors.dollar_amount"
        required
        hint="Buys as many shares as this amount covers."
      >
        <template #default="{ id, invalid, describedby }">
          <InputText
            :id="id"
            v-model="dollarAmount"
            v-bind="dollarAttrs"
            inputmode="decimal"
            autocomplete="off"
            placeholder="500.00"
            :invalid="invalid"
            :aria-describedby="describedby"
            :pt="inputTextPt"
          />
        </template>
      </FormField>

      <FormField v-else label="Shares per run" :error="errors.share_amount" required>
        <template #default="{ id, invalid, describedby }">
          <InputText
            :id="id"
            v-model="shareAmount"
            v-bind="shareAttrs"
            inputmode="decimal"
            autocomplete="off"
            placeholder="1.5"
            :invalid="invalid"
            :aria-describedby="describedby"
            :pt="inputTextPt"
          />
        </template>
      </FormField>

      <FormField label="Frequency" :error="errors.frequency" required>
        <template #default="{ id, invalid, describedby }">
          <Select
            :input-id="id"
            v-model="frequency"
            :options="[...FREQUENCY_OPTIONS]"
            option-label="label"
            option-value="value"
            class="w-full"
            :invalid="invalid"
            :aria-describedby="describedby"
            :pt="selectPt"
          />
        </template>
      </FormField>

      <div class="grid grid-cols-2 gap-4">
        <FormField label="Starts on" :error="errors.anchor_on" required>
          <template #default="{ id, invalid, describedby }">
            <DatePicker
              :input-id="id"
              v-model="anchorDate"
              date-format="yy-mm-dd"
              show-icon
              icon-display="input"
              :invalid="invalid"
              :aria-describedby="describedby"
              :pt="datePickerPt"
            />
          </template>
        </FormField>

        <FormField label="Ends on" :error="errors.end_on" hint="Optional — runs forever if empty.">
          <template #default="{ id, invalid, describedby }">
            <DatePicker
              :input-id="id"
              v-model="endDate"
              date-format="yy-mm-dd"
              show-icon
              icon-display="input"
              show-button-bar
              :invalid="invalid"
              :aria-describedby="describedby"
              :pt="datePickerPt"
            />
          </template>
        </FormField>
      </div>

      <NextRunPreview :run-dates="runDates" :loading="isPreviewLoading" />
    </form>

    <template #footer>
      <Button
        label="Cancel"
        severity="secondary"
        :disabled="props.busy"
        :pt="buttonPt"
        @click="visible = false"
      />
      <Button
        type="submit"
        form="recurring-form"
        :label="props.busy ? 'Saving…' : isEdit ? 'Save changes' : 'Create rule'"
        :disabled="props.busy"
        :pt="buttonPt"
      />
    </template>
  </Drawer>
</template>
