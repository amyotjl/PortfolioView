import { describe, expect, it } from 'vitest'
import { h, ref, type Component } from 'vue'
import { render, screen } from '@testing-library/vue'
import PrimeVue from 'primevue/config'
import AutoComplete from 'primevue/autocomplete'
import DatePicker from 'primevue/datepicker'
import Select from 'primevue/select'
import SelectButton from 'primevue/selectbutton'
import FormField from '@/components/ui/FormField.vue'
import { autoCompletePt, datePickerPt, selectButtonPt, selectPt } from '@/primevue/pt'

/**
 * The regression guard for the pass-through ARIA fixes: #65 (Select), #69
 * (SelectButton) and #70 (AutoComplete + DatePicker).
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

const SIDE_OPTIONS = [
  { label: 'Buy', value: 'buy' },
  { label: 'Sell', value: 'sell' },
]

function renderSelectButtonInFormField() {
  const model = ref('buy')

  return render(FormField, {
    props: { label: 'Side' },
    slots: {
      default: (scope: { id: string }) =>
        h(SelectButton, {
          inputId: scope.id,
          modelValue: model.value,
          'onUpdate:modelValue': (value: string) => {
            model.value = value
          },
          options: SIDE_OPTIONS,
          optionLabel: 'label',
          optionValue: 'value',
          allowEmpty: false,
          pt: selectButtonPt,
        }),
    },
    global: { plugins: [[PrimeVue, { unstyled: true }]] },
  })
}

describe('SelectButton accessible name (#69)', () => {
  it('names the role=group by its field label', () => {
    renderSelectButtonInFormField()

    // Before the fix this found 0: SelectButton declares no `inputId` prop, so
    // FormField's `<label for>` pointed at an id present nowhere in the document.
    const group = screen.getByRole('group', { name: 'Side' })
    expect(group.tagName).toBe('DIV')
  })

  it('does not leave input-id on the div as an invalid DOM attribute', () => {
    renderSelectButtonInFormField()

    const group = screen.getByRole('group', { name: 'Side' })
    expect(group.getAttribute('input-id'), 'measured as input-id="v-1-7" before').toBeNull()
  })

  it('points aria-labelledby at the visible label element', () => {
    const { container } = renderSelectButtonInFormField()

    const labelledby = screen.getByRole('group', { name: 'Side' }).getAttribute('aria-labelledby')
    const label = container.querySelector(`#${CSS.escape(labelledby as string)}`)
    expect(label?.tagName).toBe('LABEL')
    expect(label?.textContent?.trim()).toContain('Side')
  })

  it('leaves an aria-label passed at the call site alone', () => {
    // The dashboard's range presets are NOT inside a FormField and carry their
    // own aria-label; nothing is derived without an input-id, so that instance
    // must be untouched.
    render(
      {
        components: { SelectButton },
        setup: () => ({ selectButtonPt, SIDE_OPTIONS }),
        template: `
          <SelectButton
            aria-label="Date range"
            :options="SIDE_OPTIONS"
            option-label="label"
            option-value="value"
            :pt="selectButtonPt"
          />
        `,
      },
      { global: { plugins: [[PrimeVue, { unstyled: true }]] } },
    )

    expect(screen.getByRole('group', { name: 'Date range' })).toBeTruthy()
  })
})

/**
 * #70. Both components compose an inner `InputText` that carries
 * `role="combobox"`, and neither declares `aria-describedby` as a prop — so the
 * call site's value was swept onto the outer wrapper element, which has no role.
 * The assertions below are on the ROLE-BEARING element for that reason: reading
 * the attribute off the wrapper is what made this look wired-up for two
 * milestones.
 */
function renderComposedInFormField(
  component: Component,
  pt: unknown,
  fieldProps: Record<string, unknown>,
) {
  return render(FormField, {
    props: { label: 'Ticker', ...fieldProps },
    slots: {
      default: (scope: { id: string; invalid: boolean; describedby?: string }) =>
        h(component, {
          inputId: scope.id,
          invalid: scope.invalid,
          'aria-describedby': scope.describedby,
          pt,
        }),
    },
    global: { plugins: [[PrimeVue, { unstyled: true }]] },
  })
}

/** Two different components, one shared contract — hence the loose `Component`. */
const COMPOSED_CONTROLS: Array<[string, Component, unknown]> = [
  ['AutoComplete', AutoComplete, autoCompletePt],
  ['DatePicker', DatePicker, datePickerPt],
]

describe.each(COMPOSED_CONTROLS)(
  '%s description lands on the combobox, not the wrapper (#70)',
  (_name, component, pt) => {
    it('announces the hint', () => {
      renderComposedInFormField(component, pt, { hint: 'Search the local directory.' })

      const combobox = screen.getByRole('combobox', { name: 'Ticker' })
      const describedby = combobox.getAttribute('aria-describedby')
      expect(describedby, 'measured as null on the input before the fix').toBeTruthy()
      expect(document.getElementById(describedby as string)?.textContent).toContain(
        'Search the local directory.',
      )
    })

    it('announces a validation error', () => {
      renderComposedInFormField(component, pt, { error: 'Pick a ticker from the list' })

      const combobox = screen.getByRole('combobox', { name: 'Ticker' })
      const describedby = combobox.getAttribute('aria-describedby')
      expect(screen.getByRole('alert').id).toBe(describedby)
      expect(combobox.getAttribute('aria-invalid')).toBe('true')
    })

    it('adds nothing when there is neither a hint nor an error', () => {
      // The transaction drawer's Date field is exactly this case, and an absent
      // describedby there is CORRECT — asserting "always present" would have
      // pinned the wrong behaviour.
      renderComposedInFormField(component, pt, {})

      expect(
        screen.getByRole('combobox', { name: 'Ticker' }).getAttribute('aria-describedby'),
      ).toBeNull()
    })
  },
)
