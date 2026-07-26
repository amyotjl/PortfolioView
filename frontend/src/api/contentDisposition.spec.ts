import { describe, expect, it } from 'vitest'
import { filenameFromContentDisposition } from '@/api/client'

/**
 * The filename in Content-Disposition is server-supplied text that lands on an
 * anchor's `download` attribute, so it is treated as untrusted and reduced to a
 * bare basename — a path there must never influence where the browser writes.
 */
describe('filenameFromContentDisposition', () => {
  it('reads the quoted filename the export endpoint sends', () => {
    expect(
      filenameFromContentDisposition(
        'attachment; filename="portfolioview-portfolios-20260304-090807.json"',
      ),
    ).toBe('portfolioview-portfolios-20260304-090807.json')
  })

  it('reads an unquoted filename', () => {
    expect(filenameFromContentDisposition('attachment; filename=export.json')).toBe('export.json')
  })

  it('prefers the RFC 5987 filename* form and percent-decodes it', () => {
    const header = "attachment; filename=\"fallback.json\"; filename*=UTF-8''r%C3%A9sum%C3%A9.json"

    expect(filenameFromContentDisposition(header)).toBe('résumé.json')
  })

  it('falls back to the literal filename* value if it is not valid percent-encoding', () => {
    const header = "attachment; filename*=UTF-8''bad%ZZname.json"

    expect(filenameFromContentDisposition(header)).toBe('bad%ZZname.json')
  })

  it('strips any directory component from the name', () => {
    expect(filenameFromContentDisposition('attachment; filename="../../etc/passwd"')).toBe('passwd')
    expect(filenameFromContentDisposition('attachment; filename="C:\\Windows\\evil.exe"')).toBe(
      'evil.exe',
    )
    expect(filenameFromContentDisposition('attachment; filename="/abs/path/x.json"')).toBe('x.json')
  })

  it('returns null when there is no usable name, so the caller uses its fallback', () => {
    expect(filenameFromContentDisposition(null)).toBeNull()
    expect(filenameFromContentDisposition('attachment')).toBeNull()
    expect(filenameFromContentDisposition('attachment; filename=""')).toBeNull()
    expect(filenameFromContentDisposition('attachment; filename="   "')).toBeNull()
    // A name that reduces to nothing but traversal must not be accepted.
    expect(filenameFromContentDisposition('attachment; filename="/.."')).toBeNull()
  })

  it('is case-insensitive about the parameter name', () => {
    expect(filenameFromContentDisposition('ATTACHMENT; FILENAME="x.json"')).toBe('x.json')
  })
})
