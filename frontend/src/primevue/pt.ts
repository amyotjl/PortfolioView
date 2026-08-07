import type { ButtonPassThroughOptions } from 'primevue/button'
import type { InputTextPassThroughOptions } from 'primevue/inputtext'
import type { SelectPassThroughOptions, SelectProps } from 'primevue/select'
import type { DialogPassThroughOptions } from 'primevue/dialog'
import type { SelectButtonPassThroughOptions } from 'primevue/selectbutton'
import type { ToggleButtonPassThroughOptions } from 'primevue/togglebutton'
import type { ToggleSwitchPassThroughOptions } from 'primevue/toggleswitch'
import type { DataTablePassThroughOptions } from 'primevue/datatable'
import type { AutoCompletePassThroughOptions } from 'primevue/autocomplete'
import type { DatePickerPassThroughOptions } from 'primevue/datepicker'
import type { DrawerPassThroughOptions } from 'primevue/drawer'
import type { ToastPassThroughOptions } from 'primevue/toast'
import type { TextareaPassThroughOptions } from 'primevue/textarea'
import type { TagPassThroughOptions } from 'primevue/tag'
import type { PaginatorPassThroughOptions } from 'primevue/paginator'
import { fieldLabelId } from '@/lib/fieldIds'

/**
 * PrimeVue is registered in UNSTYLED mode (main.ts), so every rendered component
 * carries no built-in CSS — these pass-through (`pt`) presets are what give the
 * components their look, using the app's semantic Tailwind tokens (canvas/panel/
 * ink/line/accent/up/down, defined in assets/main.css). This is the styling
 * pattern the rest of the app's PrimeVue usage (Select, Dialog, later DataTable/
 * AutoComplete/DatePicker) builds on. Bind per component: `<Button :pt="buttonPt" />`.
 */

const BUTTON_BASE =
  'inline-flex items-center justify-center gap-2 rounded-md px-3.5 py-2 text-sm font-medium transition-colors outline-none focus-visible:ring-2 focus-visible:ring-accent-soft disabled:pointer-events-none disabled:opacity-60'

/**
 * Variants keyed off the standard Button props so callers stay declarative:
 * default -> accent, `severity="secondary"` -> bordered, `severity="danger"` ->
 * loss-red, `text` -> quiet ghost.
 */
export const buttonPt: ButtonPassThroughOptions = {
  root: ({ props }) => {
    if (props.text) return `${BUTTON_BASE} text-ink-muted hover:bg-panel-hi hover:text-ink`
    if (props.severity === 'danger') return `${BUTTON_BASE} bg-down text-white hover:brightness-110`
    if (props.severity === 'secondary')
      return `${BUTTON_BASE} border border-line bg-panel text-ink hover:bg-panel-hi`
    return `${BUTTON_BASE} bg-accent text-on-accent hover:bg-accent-hi`
  },
  label: 'whitespace-nowrap',
}

export const inputTextPt: InputTextPassThroughOptions = {
  root: ({ props }) => ({
    class: [
      'w-full rounded-md border bg-panel px-3 py-2 text-sm text-ink placeholder:text-ink-subtle outline-none transition-colors focus:ring-2 focus:ring-accent-soft disabled:cursor-not-allowed disabled:opacity-60',
      props.invalid ? 'border-down focus:border-down' : 'border-line focus:border-accent',
    ],
  }),
}

/**
 * ARIA for the Select's combobox element (#65).
 *
 * PrimeVue's unstyled Select renders the combobox as a `<span role="combobox">`.
 * A `<span>` is not a *labelable* element, so `FormField`'s `<label for>` names
 * nothing, and the component falls back to `:aria-label="ariaLabel || label"`
 * where `label` is the SELECTED VALUE — which is why every Select announced as
 * "Normal" rather than "Kind". Two things follow, both verified against
 * primevue 4.5.5's `select/Select.vue`:
 *
 *  - Passing `aria-label` at the call site does NOT fix it, so don't try again.
 *  - Any attribute Select doesn't declare as a prop (`aria-describedby`) is
 *    swept into `ptmi('root')` and lands on the wrapper `<div>`, never on the
 *    combobox — so the hint/error text was not announced either.
 *
 * `aria-labelledby` is the one hook bound straight through with no fallback
 * (`:aria-labelledby="ariaLabelledby"`), and this `label` section is v-bound
 * *after* those attributes (`mergeProps({…}, ptm('label'))`), so what we return
 * here wins the merge. Per the accessible-name spec `aria-labelledby` also
 * outranks `aria-label`, so the visible label wins over the selected value.
 *
 * The label id is DERIVED from the control id (see `lib/fieldIds`) rather than
 * threaded through every call site, so present and future Selects inside a
 * `FormField` are named automatically. A Select given an `input-id` that did
 * NOT come from `FormField` must pass its own `aria-labelledby` (respected
 * below) or omit `input-id`, or it will point at an element that isn't there.
 */
function selectComboboxAria(
  props: SelectProps,
  instance: { $attrs?: Record<string, unknown> } | undefined,
): Record<string, string> {
  const aria: Record<string, string> = {}

  const labelledby = props.ariaLabelledby ?? (props.inputId ? fieldLabelId(props.inputId) : null)
  if (labelledby) aria['aria-labelledby'] = labelledby

  // Re-home the call site's aria-describedby onto the combobox itself.
  const describedby = instance?.$attrs?.['aria-describedby']
  if (typeof describedby === 'string' && describedby) aria['aria-describedby'] = describedby

  return aria
}

/** Attrs bag as PrimeVue hands it to a pass-through callback. */
type Attrs = Record<string, unknown> | undefined

function attr(attrs: Attrs, ...names: string[]): string | undefined {
  for (const name of names) {
    const value = attrs?.[name]
    if (typeof value === 'string' && value) return value
  }
  return undefined
}

/**
 * ARIA for a control whose root is not a labelable element and which does not
 * declare `inputId` — currently `SelectButton`, whose root is
 * `<div role="group">` (#69).
 *
 * Same family as `selectComboboxAria`, one step worse. `SelectButton` declares
 * no `inputId` prop at all, so `FormField`'s `:input-id="id"` does not reach a
 * prop: it falls through into `$attrs`, gets swept into `ptmi('root')`, and is
 * rendered on the `<div>` as a bare `input-id="v-1-7"` — an attribute that means
 * nothing to anything. `<label for>` then points at an id that exists NOWHERE in
 * the document, so the group had no accessible name at all. Measured before the
 * fix: `getByRole('group', { name: 'Side', exact: true })` and `{ name: 'Invest
 * by' }` both resolved to 0, with `input-id="v-1-7"` / `"v-1-9"` on the divs.
 *
 * `ariaLabelledby` IS declared and is bound on that same root, and PT wins the
 * merge (`ptmi` is `mergeProps($attrs, ptm(key))`, so the PT section is applied
 * last) — the same lever #65 used on `selectPt.label`.
 *
 * Two deliberate details:
 *  - the leaked `input-id` is set back to `undefined`, which Vue omits from the
 *    rendered attributes. Naming the group correctly while still emitting an
 *    invalid attribute would only half-close the issue.
 *  - an `aria-label` passed at a call site is left alone (the dashboard's range
 *    presets use one, and are not inside a `FormField`). Nothing is derived
 *    without an `input-id`, so that instance is untouched.
 */
function fieldGroupAria(
  instance: { $attrs?: Record<string, unknown> } | undefined,
): Record<string, string | undefined> {
  const attrs = instance?.$attrs
  const inputId = attr(attrs, 'input-id', 'inputId')
  const labelledby = attr(attrs, 'aria-labelledby') ?? (inputId ? fieldLabelId(inputId) : undefined)

  return {
    ...(labelledby ? { 'aria-labelledby': labelledby } : {}),
    // Vue renders nothing for an undefined attribute value.
    'input-id': undefined,
    inputId: undefined,
  }
}

/**
 * `aria-describedby` for a control that composes `InputText` and does not
 * declare the attribute as a prop — `AutoComplete` (#70) and `DatePicker`.
 *
 * Both render the role-bearing element as an inner `<input role="combobox">` via
 * a child `InputText`, and both forward `id`/`invalid` to it but NOT
 * `aria-describedby`. So the call site's describedby was swept into the outer
 * wrapper's `ptmi('root')` and landed on a plain `<div>` with no role — measured
 * on the Ticker field: the wrapper carried `aria-describedby="v-1-11-hint"`
 * while the `<input role="combobox">` carried none, giving the control a
 * computed accessible description of `""`. The hint was displayed and never
 * announced; after a failed submit the validation error was not announced
 * either, even though `aria-invalid="true"` did reach the input.
 *
 * The callback runs while the CHILD `InputText` resolves its own `root`, so
 * `params.parent.attrs` is the composing component's `$attrs` — that is where
 * the describedby is. Reading `instance.$attrs` here would find nothing.
 */
function describedbyFromParent(parent: unknown): { 'aria-describedby'?: string } {
  // PrimeVue's own `*SharedPassThroughMethodOptions` types omit `attrs` from
  // `parent`, though `$params` (basecomponent) populates it at runtime — hence
  // the narrowing cast rather than a typed parameter.
  const attrs = (parent as { attrs?: Record<string, unknown> } | undefined)?.attrs
  const describedby = attr(attrs, 'aria-describedby')
  return describedby ? { 'aria-describedby': describedby } : {}
}

export const selectPt: SelectPassThroughOptions = {
  root: ({ props }) => ({
    class: [
      'flex w-full items-stretch rounded-md border bg-panel text-sm text-ink transition-colors focus-within:ring-2 focus-within:ring-accent-soft',
      props.invalid ? 'border-down' : 'border-line focus-within:border-accent',
    ],
  }),
  label: ({ props, instance }) => ({
    class: 'flex-1 truncate px-3 py-2 text-left',
    ...selectComboboxAria(props, instance),
  }),
  dropdown: 'flex w-9 shrink-0 items-center justify-center text-ink-subtle',
  clearIcon: 'text-ink-subtle',
  overlay: 'z-50 mt-1 overflow-hidden rounded-md border border-line bg-panel shadow-lg',
  listContainer: 'max-h-60 overflow-auto',
  list: 'flex flex-col gap-0.5 p-1',
  option: ({ context }) => ({
    class: [
      'cursor-pointer rounded px-3 py-2 text-sm',
      context.focused ? 'bg-panel-hi' : '',
      context.selected ? 'bg-accent-soft font-medium text-accent' : 'text-ink hover:bg-panel-hi',
    ],
  }),
  emptyMessage: 'px-3 py-2 text-sm text-ink-subtle',
}

export const dialogPt: DialogPassThroughOptions = {
  mask: 'fixed inset-0 z-40 flex items-center justify-center bg-black/50 p-4',
  root: 'w-full max-w-md rounded-lg border border-line bg-panel shadow-2xl',
  header: 'flex items-center justify-between gap-4 border-b border-line px-5 py-4',
  title: 'text-base font-semibold text-ink',
  content: 'px-5 py-4',
  footer: 'flex justify-end gap-2 border-t border-line px-5 py-4',
  pcCloseButton: {
    root: 'grid h-8 w-8 place-items-center rounded-md text-ink-subtle transition-colors hover:bg-panel-hi hover:text-ink',
  },
}

/**
 * Segmented control for the dashboard's date-range presets. SelectButton renders
 * one ToggleButton per option; `pcToggleButton` styles them, using the
 * ToggleButton `active` context so the selected preset carries the accent (its
 * label text also flips, so selection never reads by color alone).
 */
const rangeToggleButtonPt: ToggleButtonPassThroughOptions = {
  root: ({ context }) => ({
    class: [
      'cursor-pointer rounded px-3 py-1.5 text-sm font-medium tabular-nums transition-colors outline-none focus-visible:ring-2 focus-visible:ring-accent-soft',
      context.active
        ? 'bg-accent text-on-accent'
        : 'text-ink-muted hover:bg-panel-hi hover:text-ink',
    ],
  }),
  content: 'flex items-center justify-center',
  label: 'whitespace-nowrap',
}

export const selectButtonPt: SelectButtonPassThroughOptions = {
  // The ARIA half is #69 — see fieldGroupAria. `:input-id` on a SelectButton is
  // therefore load-bearing for its accessible name, exactly as it is for Select.
  root: ({ instance }) => ({
    class: 'inline-flex gap-0.5 rounded-md border border-line bg-panel p-0.5',
    ...fieldGroupAria(instance),
  }),
  pcToggleButton: rangeToggleButtonPt,
}

/**
 * Benchmark on/off switch. `slider` carries the track color (accent when on),
 * `handle` the knob; a visible label sits beside it so state is never color-only.
 */
export const toggleSwitchPt: ToggleSwitchPassThroughOptions = {
  root: 'relative inline-flex h-5 w-9 shrink-0 cursor-pointer items-center rounded-full outline-none focus-within:ring-2 focus-within:ring-accent-soft',
  input: 'absolute inset-0 z-10 m-0 h-full w-full cursor-pointer rounded-full opacity-0',
  slider: ({ context }) => ({
    class: [
      'absolute inset-0 rounded-full transition-colors',
      context.checked ? 'bg-accent' : 'bg-line-strong',
    ],
  }),
  handle: ({ context }) => ({
    class: [
      'absolute left-0.5 h-4 w-4 rounded-full bg-white shadow transition-transform',
      context.checked ? 'translate-x-4' : 'translate-x-0',
    ],
  }),
}

// --- M7: transaction / recurring UIs ----------------------------------------

/**
 * Multi-line note field. Shares the InputText look so the drawer's controls read
 * as one set; `field-sizing-content` lets it grow with typed text where supported
 * while `min-h` keeps a sane starting height everywhere else.
 */
export const textareaPt: TextareaPassThroughOptions = {
  root: ({ props }) => ({
    class: [
      'w-full min-h-20 resize-y rounded-md border bg-panel px-3 py-2 text-sm text-ink placeholder:text-ink-subtle outline-none transition-colors focus:ring-2 focus:ring-accent-soft',
      props.invalid ? 'border-down focus:border-down' : 'border-line focus:border-accent',
    ],
  }),
}

/**
 * Ticker autocomplete. `pcInputText` is the inner text field (AutoComplete
 * composes InputText), so it reuses the same border/focus treatment; the overlay
 * mirrors selectPt so both dropdowns look identical.
 */
export const autoCompletePt: AutoCompletePassThroughOptions = {
  root: 'relative w-full',
  pcInputText: {
    // describedbyFromParent is #70: the hint and the validation error have to be
    // announced on the inner `<input role="combobox">`, not on the wrapper div.
    root: ({ props, parent }) => ({
      class: [
        'w-full rounded-md border bg-panel px-3 py-2 text-sm text-ink placeholder:text-ink-subtle outline-none transition-colors focus:ring-2 focus:ring-accent-soft',
        props.invalid ? 'border-down focus:border-down' : 'border-line focus:border-accent',
      ],
      ...describedbyFromParent(parent),
    }),
  },
  overlay: 'z-50 mt-1 overflow-hidden rounded-md border border-line bg-panel shadow-lg',
  listContainer: 'max-h-60 overflow-auto',
  list: 'flex flex-col gap-0.5 p-1',
  option: ({ context }) => ({
    class: [
      'cursor-pointer rounded px-3 py-2 text-sm',
      context.focused ? 'bg-panel-hi' : '',
      'text-ink hover:bg-panel-hi',
    ],
  }),
  emptyMessage: 'px-3 py-2 text-sm text-ink-subtle',
  loader: 'absolute right-3 top-1/2 -translate-y-1/2 text-ink-subtle',
}

/**
 * Date picker. `today` and `selectedDay` both carry a non-color cue (ring vs
 * filled accent) so the highlighted day never reads by hue alone.
 */
export const datePickerPt: DatePickerPassThroughOptions = {
  root: 'w-full',
  pcInputText: {
    // Same defect as AutoComplete's. #70 flagged DatePicker as PLAUSIBLE but
    // explicitly unverified; it is now measured. The only DatePicker in the app
    // that has anything to describe is the recurring drawer's "Ends on" (hint:
    // "Optional — runs forever if empty."), and there the wrapper `<span>`
    // carried `aria-describedby="v-1-22-hint"` while its
    // `<input role="combobox">` carried none. The transaction drawer's Date
    // field cannot show this either way — it has no hint and its date is
    // pre-filled, so an absent describedby there is CORRECT, which is why a
    // first measurement attempt looked like a clean bill of health.
    root: ({ props, parent }) => ({
      class: [
        'w-full rounded-md border bg-panel px-3 py-2 text-sm text-ink placeholder:text-ink-subtle outline-none transition-colors focus:ring-2 focus:ring-accent-soft',
        props.invalid ? 'border-down focus:border-down' : 'border-line focus:border-accent',
      ],
      ...describedbyFromParent(parent),
    }),
  },
  panel: 'z-50 mt-1 rounded-md border border-line bg-panel p-3 shadow-lg',
  header: 'mb-2 flex items-center justify-between gap-2',
  title: 'flex items-center gap-1 text-sm font-medium text-ink',
  pcPrevButton: {
    root: 'grid h-7 w-7 place-items-center rounded text-ink-subtle hover:bg-panel-hi hover:text-ink',
  },
  pcNextButton: {
    root: 'grid h-7 w-7 place-items-center rounded text-ink-subtle hover:bg-panel-hi hover:text-ink',
  },
  weekDayCell: 'p-1',
  weekDay: 'text-xs font-medium text-ink-subtle',
  dayCell: 'p-0.5',
  day: ({ context }) => ({
    class: [
      'grid h-8 w-8 place-items-center rounded text-sm tabular-nums transition-colors',
      context.disabled ? 'cursor-not-allowed text-ink-subtle opacity-50' : 'cursor-pointer',
      context.selected
        ? 'bg-accent font-semibold text-on-accent'
        : context.date?.today
          ? 'ring-1 ring-accent text-ink hover:bg-panel-hi'
          : 'text-ink hover:bg-panel-hi',
    ],
  }),
}

/**
 * Right-hand form drawer for the transaction/recurring forms. Fixed to the
 * viewport edge, full-height, and capped so it never spans a wide monitor.
 */
export const drawerPt: DrawerPassThroughOptions = {
  mask: 'fixed inset-0 z-40 bg-black/50',
  root: 'fixed inset-y-0 right-0 flex w-full max-w-md flex-col border-l border-line bg-panel shadow-2xl',
  header: 'flex shrink-0 items-center justify-between gap-4 border-b border-line px-5 py-4',
  title: 'text-base font-semibold text-ink',
  content: 'flex-1 overflow-y-auto px-5 py-4',
  footer: 'flex shrink-0 justify-end gap-2 border-t border-line px-5 py-4',
  pcCloseButton: {
    root: 'grid h-8 w-8 place-items-center rounded-md text-ink-subtle transition-colors hover:bg-panel-hi hover:text-ink',
  },
}

/**
 * Transactions table. Rows keep a visible bottom rule rather than zebra striping
 * so a dense numeric table stays scannable in both themes; numeric cells are
 * right-aligned and tabular via the column's own `:pt` at the call site.
 */
export const dataTablePt: DataTablePassThroughOptions = {
  root: 'w-full',
  tableContainer: 'w-full overflow-x-auto',
  table: 'w-full border-collapse text-sm',
  thead: 'border-b border-line',
  headerRow: '',
  column: {
    headerCell:
      'whitespace-nowrap px-3 py-2.5 text-left text-xs font-semibold uppercase tracking-wide text-ink-subtle',
    bodyCell: 'px-3 py-2.5 align-middle text-ink',
  },
  bodyRow: 'border-b border-line/60 transition-colors hover:bg-panel-hi',
  emptyMessage: '',
  emptyMessageCell: 'px-3 py-10 text-center text-sm text-ink-subtle',
}

/**
 * Paginator for the transactions list. Keys follow PrimeVue 4's flat Paginator
 * PT surface (`first`/`prev`/`next`/`last`/`page`), not the `pc*` child-component
 * naming other components use.
 */
const PAGINATOR_NAV =
  'grid h-8 min-w-8 place-items-center rounded text-sm text-ink-subtle transition-colors hover:bg-panel-hi hover:text-ink disabled:pointer-events-none disabled:opacity-40'

export const paginatorPt: PaginatorPassThroughOptions = {
  root: 'flex flex-wrap items-center justify-end gap-1 border-t border-line px-3 py-2',
  content: 'flex flex-wrap items-center gap-1',
  first: PAGINATOR_NAV,
  prev: PAGINATOR_NAV,
  next: PAGINATOR_NAV,
  last: PAGINATOR_NAV,
  pages: 'flex items-center gap-1',
  page: ({ context }) => ({
    class: [
      'grid h-8 min-w-8 cursor-pointer place-items-center rounded text-sm tabular-nums transition-colors',
      context.active
        ? 'bg-accent font-semibold text-on-accent'
        : 'text-ink-muted hover:bg-panel-hi hover:text-ink',
    ],
  }),
  current: 'px-2 text-xs tabular-nums text-ink-subtle',
}

/**
 * Buy/sell and rule-status pills.
 *
 * DELIBERATELY NOT up/down COLORED. assets/main.css reserves gain-green and
 * loss-red strictly for data "so a colored number always means a real gain or
 * loss" — and a sell is not a loss, so a red SELL pill would break exactly the
 * association that rule protects. Buy/sell are distinguished with accent vs
 * neutral chrome instead, and every pill carries its own text, so the
 * distinction never rests on color alone.
 *
 * `warn` is not under that restriction and is used for a genuinely
 * needs-attention state (a paused recurring rule).
 *
 * `danger` (added for #64's import report) is the same carve-out toastPt already
 * takes: it marks an OPERATION THAT FAILED, not a value that went down, so it
 * doesn't create the false "red number = loss" association the rule protects.
 * Every pill still carries its own text, so none of this rests on color alone.
 */
export const tagPt: TagPassThroughOptions = {
  root: ({ props }) => {
    const base =
      'inline-flex items-center gap-1 rounded-full px-2 py-0.5 text-xs font-semibold uppercase tracking-wide'
    if (props.severity === 'info') return `${base} bg-accent-soft text-accent`
    if (props.severity === 'warn') return `${base} bg-warn-soft text-warn`
    if (props.severity === 'danger') return `${base} bg-down/10 text-down`
    return `${base} border border-line-strong bg-panel-hi text-ink-muted`
  },
  label: 'leading-none',
}

/**
 * Toast container, pinned bottom-right. Pointer events are disabled on the
 * container and re-enabled only on each message, so a toast never blocks clicks
 * on the page behind it while its own buttons stay clickable.
 *
 * `error` borders in loss-red is the one place a `down` token touches chrome, and
 * it is consistent with the rule's intent — it marks a failure, not a value.
 */
export const toastPt: ToastPassThroughOptions = {
  root: 'pointer-events-none fixed bottom-4 right-4 z-50 flex w-full max-w-sm flex-col gap-2',
  message: ({ props }) => ({
    class: [
      'pointer-events-auto rounded-lg border bg-panel p-3 shadow-lg',
      props.message?.severity === 'error' ? 'border-down' : 'border-line',
    ],
  }),
  messageContent: 'flex items-start gap-3',
  messageText: 'flex-1 text-sm',
  summary: 'block font-medium text-ink',
  detail: 'mt-0.5 block text-ink-muted',
  closeButton:
    'grid h-7 w-7 shrink-0 place-items-center rounded text-ink-subtle transition-colors hover:bg-panel-hi hover:text-ink',
}
