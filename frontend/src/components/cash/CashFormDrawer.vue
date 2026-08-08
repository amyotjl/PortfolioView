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
import { cashKindLabel, withdrawalProjectionNotice } from '@/lib/cash'
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
 *
 * THE TYPE FIELD IS NOT ALWAYS A CONTROL, which is the B5 fix. For an imported
 * `interest`/`dividend_cash`/`tax`/`fee` row — a kind the SelectButton cannot
 * represent — the type renders as a READ-ONLY value and the SelectButton is not
 * rendered at all. A control that cannot express the current value must not be shown
 * as if it can: while it was shown, an untouched Save rewrote a `fee` into a
 * `withdrawal` and turned broker-internal money into a user contribution.
 *
 * `defineField('kind')` stays UNCONDITIONAL below even though the SelectButton is
 * conditional — the field must remain registered and seeded, because it is what
 * carries the row's SIGN through `toCashInput`. Wrapping it in the same condition
 * would drop the sign for exactly the rows this fix exists to protect.
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
 * The label for a kind this drawer cannot offer, or null when it can.
 *
 * Read from FORM STATE, not from `props.cashTransaction`, so the value displayed and
 * the value submitted are one thing and cannot disagree. `cashKindLabel` is the same
 * function the ledger table uses, so the drawer and the table always say "Fee", never
 * "Fee" in one place and "fee" in the other.
 */
const lockedKindLabel = computed<string | null>(() =>
  values.locked_kind ? cashKindLabel(values.locked_kind) : null,
)

/**
 * The Amount hint has to follow the Type field. "The type above carries the
 * direction" is true of a deposit/withdrawal and FALSE of a locked kind, whose sign
 * is the broker's and is not shown anywhere in this drawer.
 */
const amountHint = computed(() =>
  lockedKindLabel.value
    ? 'How much money moved, in dollars. Its direction is kept exactly as recorded.'
    : 'How much money moved, in dollars. The type above carries the direction.',
)

/**
 * Live projection while typing a withdrawal — the analogue of the sell pre-flight,
 * with the copy in `lib/cash.ts` so it is unit-testable. The entry is NEVER blocked
 * for going negative; this only says what will happen.
 */
const projectionNotice = computed<string | null>(() => {
  /**
   * NOT for a locked kind, even though its `kind` is `withdrawal` as far as the sign
   * is concerned. The copy says "Withdrawing $X takes it to $Y", and a broker fee is
   * not a withdrawal — mislabelling money is worse than saying nothing (the rule
   * `negativeCashNotice` is written under), and nothing is blocked either way.
   */
  if (values.locked_kind) return null
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

      <!--
        A KIND THE SELECTBUTTON CANNOT REPRESENT IS SHOWN, NOT OFFERED (B5).
        `<dl>/<dt>/<dd>` rather than a disabled control or a FormField with a
        dangling `for`: this is a label/value pair with no control to name, and the
        term/definition roles announce the association without pretending there is
        something to operate. `errors.kind` is repeated here because the server's key
        for a rejected kind is `kind` either way, and it would otherwise be invisible
        on precisely the rows whose SelectButton is gone.
      -->
      <div v-if="lockedKindLabel" class="flex flex-col gap-1.5">
        <dl>
          <dt class="mb-1.5 text-sm font-medium text-ink">Type</dt>
          <dd class="rounded-md border border-line bg-panel-hi px-3 py-2 text-sm text-ink">
            {{ lockedKindLabel }}
          </dd>
        </dl>
        <p class="text-xs text-ink-subtle">
          Only deposits and withdrawals are entered by hand, so this type stays as
          recorded. Amount, date and notes are still editable.
        </p>
        <p v-if="errors.kind" role="alert" class="text-xs font-medium text-down">
          {{ errors.kind }}
        </p>
      </div>

      <FormField v-else label="Type" :error="errors.kind" required>
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
        :hint="amountHint"
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
