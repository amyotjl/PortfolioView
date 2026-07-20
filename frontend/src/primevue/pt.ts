import type { ButtonPassThroughOptions } from 'primevue/button'
import type { InputTextPassThroughOptions } from 'primevue/inputtext'
import type { SelectPassThroughOptions } from 'primevue/select'
import type { DialogPassThroughOptions } from 'primevue/dialog'
import type { SelectButtonPassThroughOptions } from 'primevue/selectbutton'
import type { ToggleButtonPassThroughOptions } from 'primevue/togglebutton'
import type { ToggleSwitchPassThroughOptions } from 'primevue/toggleswitch'

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

export const selectPt: SelectPassThroughOptions = {
  root: ({ props }) => ({
    class: [
      'flex w-full items-stretch rounded-md border bg-panel text-sm text-ink transition-colors focus-within:ring-2 focus-within:ring-accent-soft',
      props.invalid ? 'border-down' : 'border-line focus-within:border-accent',
    ],
  }),
  label: 'flex-1 truncate px-3 py-2 text-left',
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
  root: 'inline-flex gap-0.5 rounded-md border border-line bg-panel p-0.5',
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
