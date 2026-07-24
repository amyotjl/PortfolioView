import { describe, expect, it } from 'vitest'
import { safeRedirectTarget } from './redirect'

const FALLBACK = { name: 'portfolios' }

describe('safeRedirectTarget', () => {
  it('accepts a normal same-origin absolute path', () => {
    expect(safeRedirectTarget('/portfolios/5')).toBe('/portfolios/5')
    expect(safeRedirectTarget('/settings')).toBe('/settings')
    // Root path is fine: second char is undefined, not a slash/backslash.
    expect(safeRedirectTarget('/')).toBe('/')
  })

  it('rejects protocol-relative targets whose second char is a slash', () => {
    expect(safeRedirectTarget('//evil.com')).toEqual(FALLBACK)
  })

  it('rejects protocol-relative targets whose second char is a backslash', () => {
    // Browsers treat a leading /\ as protocol-relative too — the hardening case.
    expect(safeRedirectTarget('/\\evil.com')).toEqual(FALLBACK)
  })

  it('rejects absolute URLs and non-path values', () => {
    expect(safeRedirectTarget('https://evil.com')).toEqual(FALLBACK)
    expect(safeRedirectTarget('evil.com')).toEqual(FALLBACK)
    expect(safeRedirectTarget('')).toEqual(FALLBACK)
  })

  it('rejects array and empty query values, falling back', () => {
    expect(safeRedirectTarget(['/a', '/b'])).toEqual('/a')
    expect(safeRedirectTarget(undefined)).toEqual(FALLBACK)
    expect(safeRedirectTarget(null)).toEqual(FALLBACK)
  })

  it('honors a custom fallback', () => {
    const custom = { name: 'login' }
    expect(safeRedirectTarget('//evil.com', custom)).toEqual(custom)
  })
})
