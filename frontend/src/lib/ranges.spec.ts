import { describe, expect, it } from 'vitest'
import { presetToRange } from './ranges'

// A fixed local reference date keeps windowing deterministic across timezones.
const REFERENCE = new Date(2026, 6, 19) // 2026-07-19 (local components)

describe('presetToRange', () => {
  it('sends no bounds for ALL (inception -> last trading day)', () => {
    expect(presetToRange('ALL', REFERENCE)).toEqual({})
  })

  it('windows month-based presets from the reference date', () => {
    expect(presetToRange('1M', REFERENCE)).toEqual({ from: '2026-06-19' })
    expect(presetToRange('3M', REFERENCE)).toEqual({ from: '2026-04-19' })
    expect(presetToRange('6M', REFERENCE)).toEqual({ from: '2026-01-19' })
    expect(presetToRange('1Y', REFERENCE)).toEqual({ from: '2025-07-19' })
    expect(presetToRange('5Y', REFERENCE)).toEqual({ from: '2021-07-19' })
  })

  it('windows YTD from January 1st of the reference year', () => {
    expect(presetToRange('YTD', REFERENCE)).toEqual({ from: '2026-01-01' })
  })

  it('never sets `to` (the backend supplies its own last trading day)', () => {
    for (const preset of ['1M', '3M', '6M', 'YTD', '1Y', '5Y', 'ALL'] as const) {
      expect(presetToRange(preset, REFERENCE).to).toBeUndefined()
    }
  })
})
