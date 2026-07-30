import { describe, expect, it } from 'vitest'
import { h, ref } from 'vue'
import { render, screen } from '@testing-library/vue'
import PrimeVue from 'primevue/config'
import Select from 'primevue/select'
import FormField from '@/components/ui/FormField.vue'
import { selectPt } from '@/primevue/pt'

/**
 * The regression guard for #65.
 *
 * PrimeVue's unstyled Select renders its combobox as a `<span role="combobox">`,
 * which `<label for>` cannot name, so the component fell back to announcing the
 * SELECTED VALUE ("Normal") as the field's accessible name. `selectPt` now
 * derives `aria-labelledby` from the control id, and this spec asserts the
 * *computed accessible name* — not the attribute — because the attribute being
 * present proves nothing about what a screen reader would say.
 *
 * `getByRole('combobox', { name })` runs dom-accessibility-api's accname
 * algorithm, the same computation Playwright's `getByRole` uses in the e2e
 * acceptance test. Before the fix this query found 0 elements and
 * `{ name: 'Normal' }` found 1; both expectations below encode that flip.
 *
 * Mounted unstyled, exactly as main.ts configures PrimeVue.
 */

const KIND_OPTIONS = [
  { label: 'Normal', value: 'normal' },
  { label: 'Dividend reinvestment', value: 'drip' },
]

function renderSelectInFormField(fieldProps: Record<string, unknown> = {}) {
  const model = ref('normal')

  const utils = render(FormField, {
    props: { label: 'Kind', ...fieldProps },
    slots: {
      default: (scope: { id: string; invalid: boolean; describedby?: string }) =>
        h(Select, {
          inputId: scope.id,
          modelValue: model.value,
          'onUpdate:modelValue': (value: string) => {
            model.value = value
          },
          options: KIND_OPTIONS,
          optionLabel: 'label',
          optionValue: 'value',
          invalid: scope.invalid,
          'aria-describedby': scope.describedby,
          pt: selectPt,
        }),
    },
    global: { plugins: [[PrimeVue, { unstyled: true }]] },
  })

  return { ...utils, model }
}

describe('Select accessible name (#65)', () => {
  it('announces the field label, not the selected value', () => {
    renderSelectInFormField()

    // The acceptance criterion, at unit level: exactly one combobox named "Kind".
    const combobox = screen.getByRole('combobox', { name: 'Kind' })
    expect(combobox.tagName).toBe('SPAN')

    // And the selected value no longer masquerades as the field's name.
    expect(screen.queryByRole('combobox', { name: 'Normal' })).toBeNull()
  })

  it('still renders the selected value as the combobox content', () => {
    renderSelectInFormField()

    // The value must remain readable/announceable as the combobox's VALUE — the
    // fix must not trade one loss of information for another.
    expect(screen.getByRole('combobox', { name: 'Kind' }).textContent).toContain('Normal')
  })

  it('points aria-labelledby at the visible label element', () => {
    const { container } = renderSelectInFormField()

    const combobox = screen.getByRole('combobox', { name: 'Kind' })
    const labelledby = combobox.getAttribute('aria-labelledby')
    expect(labelledby).toBeTruthy()

    // A dangling id reference is the failure mode this derivation risks, so
    // assert the referenced element exists and is the <label>.
    const label = container.querySelector(`#${CSS.escape(labelledby as string)}`)
    expect(label?.tagName).toBe('LABEL')
    expect(label?.textContent?.trim()).toContain('Kind')
  })

  it('moves the hint/error description onto the combobox, not the wrapper div', () => {
    renderSelectInFormField({ error: 'Kind is required' })

    const combobox = screen.getByRole('combobox', { name: 'Kind' })
    const describedby = combobox.getAttribute('aria-describedby')
    expect(describedby, 'the error should describe the combobox itself').toBeTruthy()
    expect(screen.getByRole('alert').id).toBe(describedby)

    // `invalid` still reaches the combobox too.
    expect(combobox.getAttribute('aria-invalid')).toBe('true')
  })

  it('respects an explicit aria-labelledby over the derived one', () => {
    render(
      {
        components: { Select },
        setup: () => ({ selectPt, KIND_OPTIONS }),
        template: `
          <div>
            <span id="custom-label">Custom name</span>
            <Select
              input-id="some-field"
              aria-labelledby="custom-label"
              :options="KIND_OPTIONS"
              option-label="label"
              option-value="value"
              :pt="selectPt"
            />
          </div>
        `,
      },
      { global: { plugins: [[PrimeVue, { unstyled: true }]] } },
    )

    expect(screen.getByRole('combobox', { name: 'Custom name' })).toBeTruthy()
  })
})
