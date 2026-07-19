import type { ButtonPassThroughOptions } from 'primevue/button'
import type { InputTextPassThroughOptions } from 'primevue/inputtext'

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
