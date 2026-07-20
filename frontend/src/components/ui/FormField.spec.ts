import { describe, expect, it } from 'vitest'
import { h } from 'vue'
import { render, screen } from '@testing-library/vue'
import FormField from './FormField.vue'

/**
 * Component test (proves the Vitest SFC/DOM harness works) for a component with
 * real a11y logic: label association, hint/error switching, and the described-by
 * wiring exposed to the slotted control.
 */
describe('FormField', () => {
  it('associates its label with the slotted control and renders the hint', () => {
    render(FormField, {
      props: { label: 'Email', hint: 'We never share it.' },
      slots: {
        default: (scope: { id: string; invalid: boolean; describedby?: string }) =>
          h('input', { id: scope.id, 'aria-describedby': scope.describedby, type: 'email' }),
      },
    })

    // Found by its label -> the for/id association is wired correctly.
    const input = screen.getByLabelText('Email')
    expect(input.tagName).toBe('INPUT')
    expect(screen.getByText('We never share it.')).toBeTruthy()
  })

  it('shows the error as an alert and hides the hint when an error is present', () => {
    render(FormField, {
      props: { label: 'Password', hint: 'At least 8 characters.', error: 'Password is required' },
      slots: { default: '<input type="password" />' },
    })

    expect(screen.getByRole('alert').textContent).toContain('Password is required')
    expect(screen.queryByText('At least 8 characters.')).toBeNull()
  })
})
