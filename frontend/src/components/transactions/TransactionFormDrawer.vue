<script setup lang="ts">
import { computed, shallowRef, watch } from 'vue'
import { useForm } from 'vee-validate'
import { toTypedSchema } from '@vee-validate/zod'
import Drawer from 'primevue/drawer'
import AutoComplete from 'primevue/autocomplete'
import DatePicker from 'primevue/datepicker'
import InputText from 'primevue/inputtext'
import Textarea from 'primevue/textarea'
import Select from 'primevue/select'
import SelectButton from 'primevue/selectbutton'
import Button from 'primevue/button'
import FormField from '@/components/ui/FormField.vue'
import FormAlert from '@/components/ui/FormAlert.vue'
import {
  useHoldingPreflight,
  useInstrumentPrice,
  useInstrumentSearch,
  instrumentLabel,
} from '@/composables/useInstrumentForm'
import {
  transactionFormSchema,
  emptyTransactionForm,
  TRANSACTION_FORM_FIELDS,
  type TransactionFormValues,
} from '@/forms/transaction'
import { resolveInstrumentId, type InstrumentIdMap } from '@/lib/instrumentIds'
import { decimalGreaterThan, isDecimalZero } from '@/lib/decimal'
import {
  marketClosedNotice,
  todayIso,
  isoToPickerDate,
  pickerDateToIso,
} from '@/lib/tradingDays'
import { mapApiError } from '@/lib/formErrors'
import { formatCurrency } from '@/lib/format'
import {
  autoCompletePt,
  buttonPt,
  datePickerPt,
  drawerPt,
  inputTextPt,
  selectPt,
  selectButtonPt,
  textareaPt,
} from '@/primevue/pt'
import type { InstrumentSearchResult, Transaction } from '@/types'

/**
 * Create (transaction = null) or edit (transaction set) drawer.
 *
 * Owns its vee-validate form but NOT the mutation: the parent runs create/update
 * so it can layer the optimistic insert + undo toast on top (#49). This
 * component reports a validated payload via `submit` and is told the outcome
 * through `applyServerError`, which keeps the optimistic bookkeeping in one place
 * instead of split across both.
 */
const visible = defineModel<boolean>('visible', { required: true })

const props = defineProps<{
  portfolioId: number
  transaction?: Transaction | null
  /** symbol -> instrument_id, derived from the portfolio's own payloads. */
  instrumentIds: InstrumentIdMap
  busy?: boolean
}>()

const emit = defineEmits<{ submit: [values: TransactionFormValues] }>()

const isEdit = computed(() => Boolean(props.transaction))
const title = computed(() => (isEdit.value ? 'Edit transaction' : 'Add transaction'))

const SIDE_OPTIONS = [
  { label: 'Buy', value: 'buy' },
  { label: 'Sell', value: 'sell' },
] as const

const KIND_OPTIONS = [
  { label: 'Normal', value: 'normal' },
  { label: 'Dividend reinvestment', value: 'dividend_reinvestment' },
] as const

const { results: symbolResults, search } = useInstrumentSearch()
const { fetchClose, isLoading: isPriceLoading } = useInstrumentPrice()
const { fetchShares, isLoading: isPreflightLoading } = useHoldingPreflight()

const formError = shallowRef<string | null>(null)
/** Shares held at the chosen date, or null when unknown/not applicable. */
const heldShares = shallowRef<string | null>(null)

/**
 * The explicit generic matters: `transactionFormSchema` carries zod transforms
 * (symbol uppercasing, notes '' -> null), which makes vee-validate's inferred
 * field types widen to `unknown`. Pinning the form shape keeps `values` and every
 * `defineField` binding typed as the string fields the inputs actually bind to.
 */
const { defineField, handleSubmit, errors, setErrors, resetForm, values } =
  useForm<TransactionFormValues>({
    validationSchema: toTypedSchema(transactionFormSchema),
    initialValues: emptyTransactionForm(todayIso()),
  })

const [symbol] = defineField('symbol')
const [side] = defineField('side')
const [kind] = defineField('kind')
const [shares, sharesAttrs] = defineField('shares')
const [price, priceAttrs] = defineField('price')
const [fees, feesAttrs] = defineField('fees')
const [executedOn] = defineField('executed_on')
const [notes, notesAttrs] = defineField('notes')

/** DatePicker speaks `Date`; the form and API speak `YYYY-MM-DD`. */
const executedOnDate = computed<Date | null>({
  get: () => isoToPickerDate(executedOn.value),
  set: (date) => {
    const iso = pickerDateToIso(date)
    if (iso) executedOn.value = iso
  },
})

const closedNotice = computed(() => marketClosedNotice(values.executed_on ?? ''))

const resolvedInstrumentId = computed(() =>
  resolveInstrumentId(props.instrumentIds, values.symbol),
)

/**
 * Advisory sell warning. Fires only when we actually know the position and the
 * requested shares exceed it — compared as decimal STRINGS, never floats
 * (lib/decimal.ts). The server's replay stays authoritative; a silent null here
 * must not read as approval, which is why the copy below says "may".
 */
const sellWarning = computed<string | null>(() => {
  if (values.side !== 'sell') return null
  const held = heldShares.value
  const wanted = values.shares
  if (!held || !wanted) return null
  if (!decimalGreaterThan(wanted, held)) return null

  const position = isDecimalZero(held)
    ? 'no shares'
    : `${held} share${held === '1' ? '' : 's'}`
  return `This portfolio holds ${position} of ${values.symbol} on ${values.executed_on}. Selling ${wanted} may be rejected — short positions are not allowed.`
})

const estimatedTotal = computed<string | null>(() => {
  // Display-only: an approximate order value is fine to compute in float, and is
  // never sent anywhere. Money that crosses the wire stays a string.
  const s = Number(values.shares)
  const p = Number(values.price)
  const f = Number(values.fees || '0')
  if (!Number.isFinite(s) || !Number.isFinite(p) || !Number.isFinite(f)) return null
  if (s <= 0 || p <= 0) return null
  const gross = s * p
  return formatCurrency(values.side === 'sell' ? gross - f : gross + f)
})

// --- Seeding -----------------------------------------------------------------

watch(visible, (open) => {
  if (!open) return
  formError.value = null
  heldShares.value = null
  symbolResults.value = []

  resetForm({
    values: props.transaction
      ? {
          symbol: props.transaction.symbol,
          side: props.transaction.side,
          kind: props.transaction.kind,
          shares: props.transaction.shares,
          price: props.transaction.price,
          fees: props.transaction.fees,
          executed_on: props.transaction.executed_on,
          notes: props.transaction.notes,
        }
      : emptyTransactionForm(todayIso()),
  })
})

// --- Reactive lookups --------------------------------------------------------

/**
 * Prefill the cached close when symbol+date are both set — but never clobber a
 * price the user has already typed, and never on the edit form's initial seed
 * (an existing transaction's recorded price is the truth, not today's close).
 */
watch(
  () => [values.symbol, values.executed_on] as const,
  async ([nextSymbol, nextDate], previous) => {
    if (!visible.value || !nextSymbol || !nextDate) return
    // Skip the seed pass, where `previous` is undefined.
    if (!previous) return
    const userTypedPrice = Boolean(values.price) && values.price !== ''
    const symbolChanged = previous[0] !== nextSymbol
    if (userTypedPrice && !symbolChanged) return

    const close = await fetchClose(resolvedInstrumentId.value, nextDate)
    if (close) price.value = close
  },
)

/** Refresh the sell pre-flight whenever the side, symbol or date changes. */
watch(
  () => [values.side, values.symbol, values.executed_on] as const,
  async ([nextSide, nextSymbol, nextDate]) => {
    if (!visible.value || nextSide !== 'sell' || !nextSymbol || !nextDate) {
      heldShares.value = null
      return
    }
    heldShares.value = await fetchShares(
      props.portfolioId,
      resolvedInstrumentId.value,
      nextDate,
    )
  },
  { immediate: true },
)

// --- Submit ------------------------------------------------------------------

const onSubmit = handleSubmit((formValues) => {
  formError.value = null
  emit('submit', formValues)
})

/**
 * Called by the parent when the server rejects the submission: maps 422 details
 * onto the fields and shows anything unmapped (notably the `base` no-short-
 * position message, which names the first offending date) above the form.
 */
function applyServerError(error: unknown): void {
  const mapped = mapApiError(error, TRANSACTION_FORM_FIELDS)
  if (Object.keys(mapped.fieldErrors).length > 0) setErrors(mapped.fieldErrors)
  formError.value = mapped.formMessage
}

function close(): void {
  visible.value = false
}

defineExpose({ applyServerError })

function onSymbolComplete(event: { query: string }): void {
  void search(event.query)
}

/** AutoComplete v-model holds either the typed string or a picked object. */
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
    <form id="transaction-form" class="flex flex-col gap-4" novalidate @submit.prevent="onSubmit">
      <FormAlert :message="formError" />

      <FormField label="Side" :error="errors.side" required>
        <template #default="{ id }">
          <SelectButton
            :input-id="id"
            v-model="side"
            :options="[...SIDE_OPTIONS]"
            option-label="label"
            option-value="value"
            :allow-empty="false"
            :pt="selectButtonPt"
          />
        </template>
      </FormField>

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
            placeholder="e.g. AAPL"
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

      <FormField label="Date" :error="errors.executed_on" required>
        <template #default="{ id, invalid, describedby }">
          <DatePicker
            :input-id="id"
            v-model="executedOnDate"
            date-format="yy-mm-dd"
            show-icon
            icon-display="input"
            :invalid="invalid"
            :aria-describedby="describedby"
            :pt="datePickerPt"
          />
        </template>
      </FormField>

      <!--
        Weekend copy (#49 AC): the transaction is still accepted; this explains
        that the market was shut. Not an error, so it is styled as information and
        announced politely rather than assertively.
      -->
      <p
        v-if="closedNotice"
        class="rounded-md border border-line bg-panel-hi px-3 py-2 text-sm text-ink-muted"
        role="status"
      >
        {{ closedNotice }}
      </p>

      <div class="grid grid-cols-2 gap-4">
        <FormField label="Shares" :error="errors.shares" required>
          <template #default="{ id, invalid, describedby }">
            <InputText
              :id="id"
              v-model="shares"
              v-bind="sharesAttrs"
              inputmode="decimal"
              autocomplete="off"
              placeholder="0"
              :invalid="invalid"
              :aria-describedby="describedby"
              :pt="inputTextPt"
            />
          </template>
        </FormField>

        <FormField
          label="Price"
          :error="errors.price"
          required
          :hint="isPriceLoading ? 'Looking up the close…' : 'Prefilled from the cached close.'"
        >
          <template #default="{ id, invalid, describedby }">
            <InputText
              :id="id"
              v-model="price"
              v-bind="priceAttrs"
              inputmode="decimal"
              autocomplete="off"
              placeholder="0.00"
              :invalid="invalid"
              :aria-describedby="describedby"
              :pt="inputTextPt"
            />
          </template>
        </FormField>
      </div>

      <!--
        Advisory sell pre-flight (#49 AC). role="status" not "alert": the server
        is authoritative and a real rejection arrives as a 422 in FormAlert above.
      -->
      <p
        v-if="sellWarning"
        class="rounded-md border border-warn bg-warn-soft px-3 py-2 text-sm text-ink"
        role="status"
      >
        {{ sellWarning }}
        <span v-if="isPreflightLoading" class="text-ink-subtle">(checking…)</span>
      </p>

      <div class="grid grid-cols-2 gap-4">
        <FormField label="Fees" :error="errors.fees">
          <template #default="{ id, invalid, describedby }">
            <InputText
              :id="id"
              v-model="fees"
              v-bind="feesAttrs"
              inputmode="decimal"
              autocomplete="off"
              placeholder="0.00"
              :invalid="invalid"
              :aria-describedby="describedby"
              :pt="inputTextPt"
            />
          </template>
        </FormField>

        <FormField label="Kind" :error="errors.kind">
          <template #default="{ id, invalid, describedby }">
            <Select
              :input-id="id"
              v-model="kind"
              :options="[...KIND_OPTIONS]"
              option-label="label"
              option-value="value"
              class="w-full"
              :invalid="invalid"
              :aria-describedby="describedby"
              :pt="selectPt"
            />
          </template>
        </FormField>
      </div>

      <FormField label="Notes" :error="errors.notes">
        <template #default="{ id, invalid, describedby }">
          <Textarea
            :id="id"
            v-model="notes"
            v-bind="notesAttrs"
            rows="3"
            placeholder="Optional"
            :invalid="invalid"
            :aria-describedby="describedby"
            :pt="textareaPt"
          />
        </template>
      </FormField>

      <p v-if="estimatedTotal" class="text-sm text-ink-muted">
        Estimated {{ values.side === 'sell' ? 'proceeds' : 'cost' }}:
        <span class="font-medium tabular-nums text-ink">{{ estimatedTotal }}</span>
      </p>
    </form>

    <template #footer>
      <Button
        label="Cancel"
        severity="secondary"
        :disabled="props.busy"
        :pt="buttonPt"
        @click="close"
      />
      <Button
        type="submit"
        form="transaction-form"
        :label="props.busy ? 'Saving…' : isEdit ? 'Save changes' : 'Add transaction'"
        :disabled="props.busy"
        :pt="buttonPt"
      />
    </template>
  </Drawer>
</template>
