import { describe, expect, it } from 'vitest'
import { fieldErrorId, fieldHintId, fieldLabelId } from './fieldIds'

/**
 * WHAT THIS FILE DOES AND DOES NOT LOCK — corrected per #70.
 *
 * It locks the PURE FUNCTIONS only: the suffixes, and that the three ids stay
 * distinct. It does NOT lock the `FormField` ↔ `primevue/pt.ts` contract, which
 * an earlier version of this comment claimed. Drift the convention on one side
 * only — change what `FormField` renders, or what a PT preset re-derives — and
 * every test below stays green.
 *
 * `primevue/selectA11y.spec.ts` is the real guard for that contract: it renders
 * the components inside a real `FormField` and asserts the *computed* accessible
 * name and description, which is the thing that actually breaks.
 */
describe('fieldIds', () => {
  it('derives the satellite ids from the control id', () => {
    expect(fieldLabelId('v-1-24')).toBe('v-1-24-label')
    expect(fieldHintId('v-1-24')).toBe('v-1-24-hint')
    expect(fieldErrorId('v-1-24')).toBe('v-1-24-error')
  })

  it('keeps the three ids distinct for the same field', () => {
    const ids = [fieldLabelId('f'), fieldHintId('f'), fieldErrorId('f')]
    expect(new Set(ids).size).toBe(3)
  })
})
