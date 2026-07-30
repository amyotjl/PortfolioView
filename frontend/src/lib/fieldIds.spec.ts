import { describe, expect, it } from 'vitest'
import { fieldErrorId, fieldHintId, fieldLabelId } from './fieldIds'

/**
 * These suffixes are a contract between `FormField` (which renders the elements)
 * and `primevue/pt.ts` (which re-derives the label id to name a Select). Locking
 * them here means a rename has to be a deliberate, two-sided change.
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
