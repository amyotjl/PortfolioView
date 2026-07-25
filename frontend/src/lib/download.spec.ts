import { afterEach, describe, expect, it, vi } from 'vitest'
import { saveBlob } from '@/lib/download'

/**
 * These specs stub createObjectURL/revokeObjectURL (absent on some non-browser
 * hosts, which is the point of the guard inside saveBlob) to assert the anchor
 * dance and, crucially, that the object URL is ALWAYS revoked — not revoking
 * leaks the whole exported file for the tab's lifetime.
 */
describe('saveBlob', () => {
  afterEach(() => {
    vi.unstubAllGlobals()
    vi.restoreAllMocks()
  })

  function stubObjectUrl() {
    const createObjectURL = vi.fn(() => 'blob:fake-url')
    const revokeObjectURL = vi.fn()
    vi.stubGlobal('URL', { ...URL, createObjectURL, revokeObjectURL })
    return { createObjectURL, revokeObjectURL }
  }

  it('clicks a download anchor carrying the filename, then cleans up', () => {
    const { createObjectURL, revokeObjectURL } = stubObjectUrl()
    const click = vi.fn()
    const anchor = document.createElement('a')
    anchor.click = click
    vi.spyOn(document, 'createElement').mockReturnValue(anchor)

    const blob = new Blob(['{}'], { type: 'application/json' })
    saveBlob(blob, 'portfolioview-portfolios-20260304-090807.json')

    expect(createObjectURL).toHaveBeenCalledWith(blob)
    expect(anchor.download).toBe('portfolioview-portfolios-20260304-090807.json')
    expect(anchor.href).toContain('blob:fake-url')
    expect(click).toHaveBeenCalledOnce()
    expect(revokeObjectURL).toHaveBeenCalledWith('blob:fake-url')
    expect(document.body.contains(anchor)).toBe(false)
  })

  it('revokes the object URL even if the click throws', () => {
    const { revokeObjectURL } = stubObjectUrl()
    const anchor = document.createElement('a')
    anchor.click = vi.fn(() => {
      throw new Error('popup blocked')
    })
    vi.spyOn(document, 'createElement').mockReturnValue(anchor)

    expect(() => saveBlob(new Blob(['x']), 'x.json')).toThrow('popup blocked')
    expect(revokeObjectURL).toHaveBeenCalledWith('blob:fake-url')
  })

  it('is a no-op where createObjectURL does not exist, instead of throwing', () => {
    vi.stubGlobal('URL', { revokeObjectURL: vi.fn() })
    const createElement = vi.spyOn(document, 'createElement')

    expect(() => saveBlob(new Blob(['x']), 'x.json')).not.toThrow()
    expect(createElement).not.toHaveBeenCalled()
  })
})
