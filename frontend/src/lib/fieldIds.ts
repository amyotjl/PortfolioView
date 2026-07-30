/**
 * The one place that knows how a form field's satellite element ids are derived
 * from the control's own id.
 *
 * `FormField` generates the control id (`useId()`) and renders the label, hint
 * and error elements with these derived ids. `primevue/pt.ts` re-derives the
 * LABEL id from the control id so `selectPt` can wire `aria-labelledby` for
 * every Select without each call site remembering to (#65) — which only works
 * while both sides agree on the derivation, hence this module.
 *
 * Keep the suffixes stable: changing one here changes the ids PrimeVue's
 * pass-through presets point at.
 */

export function fieldLabelId(fieldId: string): string {
  return `${fieldId}-label`
}

export function fieldHintId(fieldId: string): string {
  return `${fieldId}-hint`
}

export function fieldErrorId(fieldId: string): string {
  return `${fieldId}-error`
}
