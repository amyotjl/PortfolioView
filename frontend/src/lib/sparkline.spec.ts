import { describe, expect, it } from 'vitest'
import { buildSparkline } from './sparkline'

describe('buildSparkline', () => {
  it('returns null when there are fewer than two points', () => {
    expect(buildSparkline([])).toBeNull()
    expect(buildSparkline([42])).toBeNull()
  })

  it('maps an ascending series to a bottom-to-top path within the viewBox', () => {
    const geo = buildSparkline([1, 2, 3], { width: 240, height: 40, padding: 3 })
    expect(geo).not.toBeNull()
    // min=1,max=3 -> range 2; innerHeight 34; step 120. y: 1->37, 2->20, 3->3.
    expect(geo!.line).toBe('M0 37 L120 20 L240 3')
    expect(geo!.area).toBe('M0 37 L120 20 L240 3 L240 40 L0 40 Z')
    expect(geo!.last).toEqual({ x: 240, y: 3 })
    expect(geo!.width).toBe(240)
    expect(geo!.height).toBe(40)
  })

  it('centers a flat series vertically instead of dividing by zero', () => {
    const geo = buildSparkline([5, 5, 5], { width: 240, height: 40 })
    expect(geo!.line).toBe('M0 20 L120 20 L240 20')
  })

  it('skips non-finite values before drawing', () => {
    const geo = buildSparkline([1, Number.NaN, 3], { width: 240, height: 40, padding: 3 })
    // Only the two finite points remain, so they span the full width.
    expect(geo!.line).toBe('M0 37 L240 3')
  })
})
