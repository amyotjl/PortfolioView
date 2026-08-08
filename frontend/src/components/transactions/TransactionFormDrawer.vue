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
import AdvisoryNotice from '@/components/ui/AdvisoryNotice.vue'
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
import { sellPreflightMessage } from '@/lib/decimal'
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
const { fetchPrice, isLoading: isPriceLoading } = useInstrumentPrice()
const { fetchShares, isLoading: isPreflightLoading } = useHoldingPreflight()

const formError = shallowRef<string | null>(null)
/** Shares held at the chosen date, or null when unknown/not applicable. */
const heldShares = shallowRef<string | null>(null)
/**
 * The trading day the server actually priced against (<= the chosen date), taken
 * from the price lookup. It is the only signal we get for how far the trading
 * calendar reaches, and the sell pre-flight is quantized to the same day — so
 * when this lags the chosen date, the position figure cannot see transactions in
 * between and must not be reported as a shortfall.
 */
const effectiveDate = shallowRef<string | null>(null)

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
 * Advisory sell warning — the copy (and its stale-position branch) lives in
 * lib/decimal.ts so it can be unit-tested. Compared as decimal STRINGS, never
 * floats. The server's replay stays authoritative; a null here must not be read
 * as approval.
 */
const sellWarning = computed<string | null>(() => {
  if (values.side !== 'sell') return null
  const held = heldShares.value
  if (!held) return null

  return sellPreflightMessage({
    symbol: values.symbol,
    requestedShares: values.shares,
    heldShares: held,
    on: values.executed_on,
    effectiveOn: effectiveDate.value,
  })
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
  effectiveDate.value = null
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
 * Look up the cached close when symbol+date are both set.
 *
 * The lookup runs even when we will NOT overwrite the price field, because its
 * response also carries the effective trading day the sell pre-flight needs. Only
 * the assignment to `price` is conditional: never clobber a price the user typed,
 * and never overwrite an existing transaction's recorded price (which is the
 * truth, not today's close).
 */
watch(
  () => [values.symbol, values.executed_on] as const,
  async ([nextSymbol, nextDate], previous) => {
    if (!visible.value || !nextSymbol || !nextDate) {
      effectiveDate.value = null
      return
    }

    const result = await fetchPrice(resolvedInstrumentId.value, nextDate)
    effectiveDate.value = result?.date ?? null
    if (!result) return

    // `previous` is undefined on the seed pass — don't prefill over seeded values.
    if (!previous) return
    const userTypedPrice = Boolean(values.price)
    const symbolChanged = previous[0] !== nextSymbol
    if (userTypedPrice && !symbolChanged) return

    price.value = result.close
  },
  { immediate: true },
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
  <!--
    `:aria-label="title"` names the dialog. PrimeVue 4's unstyled Drawer sets
    `role="dialog"` but renders its header as a plain `<div>` with no id and wires no
    `aria-labelledby`, so this drawer had NO accessible name — and since #80 the
    Transactions page mounts a second drawer (cash), which makes an unnamed
    `getByRole('dialog')` mean "whichever one happens to be open". See the fuller note
    in CashFormDrawer.vue.
  -->
  <Drawer
    v-model:visible="visible"
    position="right"
    :header="title"
    :aria-label="title"
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
        announced politely rather than assertively — which is exactly what
        AdvisoryNotice is (this markup was inlined here twice before #80).
      -->
      <AdvisoryNotice :message="closedNotice" tone="info" />

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
      <AdvisoryNotice :message="sellWarning" tone="warn">
        <span v-if="isPreflightLoading" class="text-ink-subtle">(checking…)</span>
      </AdvisoryNotice>

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
            <!--
              This Select is named by `selectPt`, not by the `<label for>` above:
              PrimeVue renders the combobox as a <span>, which `for` cannot name.
              selectPt derives aria-labelledby from `input-id` — so passing
              `:input-id="id"` here is load-bearing for the accessible name, not
              just for focus. See primevue/pt.ts (#65).
            -->
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
