<script setup lang="ts">
import { computed, shallowRef, watch } from 'vue'
import { useForm } from 'vee-validate'
import { toTypedSchema } from '@vee-validate/zod'
import Drawer from 'primevue/drawer'
import DatePicker from 'primevue/datepicker'
import InputText from 'primevue/inputtext'
import Textarea from 'primevue/textarea'
import SelectButton from 'primevue/selectbutton'
import Button from 'primevue/button'
import FormField from '@/components/ui/FormField.vue'
import FormAlert from '@/components/ui/FormAlert.vue'
import AdvisoryNotice from '@/components/ui/AdvisoryNotice.vue'
import {
  cashFormSchema,
  emptyCashForm,
  toCashForm,
  CASH_FORM_FIELDS,
  CASH_KIND_OPTIONS,
  type CashFormValues,
} from '@/forms/cash'
import { withdrawalProjectionNotice } from '@/lib/cash'
import {
  marketClosedNotice,
  todayIso,
  isoToPickerDate,
  pickerDateToIso,
} from '@/lib/tradingDays'
import { mapApiError } from '@/lib/formErrors'
import {
  buttonPt,
  datePickerPt,
  drawerPt,
  inputTextPt,
  selectButtonPt,
  textareaPt,
} from '@/primevue/pt'
import type { CashTransaction } from '@/types'

/**
 * Create (cashTransaction = null) or edit (set) drawer for a deposit/withdrawal.
 *
 * Owns its vee-validate form but NOT the mutation, matching `TransactionFormDrawer`:
 * the parent runs create/update so it can own the toast, and is told the outcome
 * through `applyServerError`. The parent must also keep the "DRAWER CLOSES ONLY ON
 * SUCCESS" ordering — closing up-front and reopening on failure re-runs the
 * `watch(visible)` seed below, which resetForm()s away both the 422 message and
 * everything the user typed. That bug is trivially reintroduced.
 *
 * FOUR FIELDS, NOT A MODE OF THE TRANSACTION DRAWER. See forms/cash.ts for the
 * reasoning; the short version is that six of eight fields would be conditioned
 * away and three of that drawer's reactive side effects are keyed on `symbol`, so
 * every guard would be a future place an `/instruments/:id/price` request leaks for
 * a deposit.
 */
const visible = defineModel<boolean>('visible', { required: true })

const props = defineProps<{
  cashTransaction?: CashTransaction | null
  /**
   * The portfolio's current cash balance from /summary, or null when it does not
   * track cash yet. Drives the live withdrawal projection. `null` is NOT zero.
   */
  cashBalance?: string | null
  busy?: boolean
}>()

const emit = defineEmits<{ submit: [values: CashFormValues] }>()

const isEdit = computed(() => Boolean(props.cashTransaction))
const title = computed(() => (isEdit.value ? 'Edit cash movement' : 'Add cash movement'))

const formError = shallowRef<string | null>(null)

/**
 * The explicit generic matters for the same reason it does in the transaction
 * drawer: `cashFormSchema` carries a zod transform (notes '' -> null), which widens
 * vee-validate's inferred field types to `unknown`. Pinning the form shape keeps
 * every `defineField` binding typed as the string field its input binds to.
 */
const { defineField, handleSubmit, errors, setErrors, resetForm, values } =
  useForm<CashFormValues>({
    validationSchema: toTypedSchema(cashFormSchema),
    initialValues: emptyCashForm(todayIso()),
  })

const [kind] = defineField('kind')
const [amount, amountAttrs] = defineField('amount')
const [occurredOn] = defineField('occurred_on')
const [notes, notesAttrs] = defineField('notes')

/** DatePicker speaks `Date`; the form and API speak `YYYY-MM-DD`. */
const occurredOnDate = computed<Date | null>({
  get: () => isoToPickerDate(occurredOn.value),
  set: (date) => {
    const iso = pickerDateToIso(date)
    if (iso) occurredOn.value = iso
  },
})

/**
 * A cash movement is bucketed to the first trading day >= `occurred_on`, exactly
 * like a trade, so the weekend copy applies verbatim and names no specific
 * effective date (a Monday holiday would make any date we guessed wrong).
 */
const closedNotice = computed(() => marketClosedNotice(values.occurred_on ?? ''))

/**
 * Live projection while typing a withdrawal — the analogue of the sell pre-flight,
 * with the copy in `lib/cash.ts` so it is unit-testable. The entry is NEVER blocked
 * for going negative; this only says what will happen.
 */
const projectionNotice = computed<string | null>(() => {
  if (values.kind !== 'withdrawal') return null
  return withdrawalProjectionNotice({
    cashBalance: props.cashBalance ?? null,
    amount: values.amount ?? '',
  })
})

// --- Seeding -----------------------------------------------------------------

watch(visible, (open) => {
  if (!open) return
  formError.value = null

  // `toCashForm` is the INVERSE of the `toCashInput` the parent submits, and it has
  // to be: the wire amount is signed, so seeding it verbatim hands `decimalField` a
  // `-500` it rejects outright and makes every withdrawal un-editable. It also picks
  // the offered kind by sign for an imported internal kind. See forms/cash.ts.
  resetForm({
    values: props.cashTransaction ? toCashForm(props.cashTransaction) : emptyCashForm(todayIso()),
  })
})

// --- Submit ------------------------------------------------------------------

const onSubmit = handleSubmit((formValues) => {
  formError.value = null
  emit('submit', formValues)
})

/** Maps 422 details onto the fields; anything unmapped shows above the form. */
function applyServerError(error: unknown): void {
  const mapped = mapApiError(error, CASH_FORM_FIELDS)
  if (Object.keys(mapped.fieldErrors).length > 0) setErrors(mapped.fieldErrors)
  formError.value = mapped.formMessage
}

function close(): void {
  visible.value = false
}

defineExpose({ applyServerError })
</script>

<template>
  <!--
    `:aria-label="title"` is LOAD-BEARING, and it is the same class of gap as #69/#70.
    PrimeVue 4's unstyled Drawer puts `role="dialog"` on its root and renders the
    header as a plain `<div>` with NO id and NO `aria-labelledby` — so the drawer has
    no accessible name at all, and a `<Dialog>` (which does wire one) behaves
    differently from a `<Drawer>`. That matters beyond announcement: this page mounts
    TWO drawers (trades and cash), and without a name the only way to address either
    is an unnamed `getByRole('dialog')`, which silently means "whichever one is open"
    and becomes a strict-mode violation the moment both are. `$attrs` reaches the root
    through `ptmi('root')`, so one attribute fixes both problems.
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
    <form id="cash-form" class="flex flex-col gap-4" novalidate @submit.prevent="onSubmit">
      <FormAlert :message="formError" />

      <FormField label="Type" :error="errors.kind" required>
        <template #default="{ id }">
          <!--
            `:input-id="id"` is LOAD-BEARING FOR THE ACCESSIBLE NAME, not just for
            focus. SelectButton's root is a bare `<div role="group">` with no
            `inputId` prop, so `<label for>` cannot name it; `selectButtonPt.root`'s
            fieldGroupAria derives aria-labelledby from this leaked attribute and
            then nulls the invalid attribute itself (#69). Do NOT add an
            `aria-label` here — fieldGroupAria deliberately leaves a call-site one
            alone, so it would compete with the label.
          -->
          <SelectButton
            :input-id="id"
            v-model="kind"
            :options="[...CASH_KIND_OPTIONS]"
            option-label="label"
            option-value="value"
            :allow-empty="false"
            :pt="selectButtonPt"
          />
        </template>
      </FormField>

      <FormField
        label="Amount"
        :error="errors.amount"
        required
        hint="How much money moved, in dollars. The type above carries the direction."
      >
        <template #default="{ id, invalid, describedby }">
          <InputText
            :id="id"
            v-model="amount"
            v-bind="amountAttrs"
            inputmode="decimal"
            autocomplete="off"
            placeholder="0.00"
            :invalid="invalid"
            :aria-describedby="describedby"
            :pt="inputTextPt"
          />
        </template>
      </FormField>

      <FormField label="Date" :error="errors.occurred_on" required>
        <template #default="{ id, invalid, describedby }">
          <!--
            DatePicker does not forward `aria-describedby` on its own, so it is
            bound explicitly at the call site (#70). With no hint and no error on
            this field an ABSENT describedby is the correct outcome.
          -->
          <DatePicker
            :input-id="id"
            v-model="occurredOnDate"
            date-format="yy-mm-dd"
            show-icon
            icon-display="input"
            :invalid="invalid"
            :aria-describedby="describedby"
            :pt="datePickerPt"
          />
        </template>
      </FormField>

      <AdvisoryNotice :message="closedNotice" tone="info" />
      <AdvisoryNotice :message="projectionNotice" tone="warn" />

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
        form="cash-form"
        :label="props.busy ? 'Saving…' : isEdit ? 'Save changes' : 'Add cash movement'"
        :disabled="props.busy"
        :pt="buttonPt"
      />
    </template>
  </Drawer>
</template>
