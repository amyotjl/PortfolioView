import { describe, expect, it } from 'vitest'
import {
  isWeekend,
  isoToPickerDate,
  marketClosedNotice,
  pickerDateToIso,
  todayIso,
  weekdayName,
} from './tradingDays'

describe('weekdayName', () => {
  it('names the ET calendar weekday', () => {
    expect(weekdayName('2026-07-20')).toBe('Monday')
    expect(weekdayName('2026-07-24')).toBe('Friday')
    expect(weekdayName('2026-07-25')).toBe('Saturday')
    expect(weekdayName('2026-07-26')).toBe('Sunday')
  })

  it('returns null for malformed input instead of guessing', () => {
    for (const bad of ['', '2026-7-1', '20260701', 'not-a-date', '2026-13-01']) {
      expect(weekdayName(bad), bad).toBeNull()
    }
  })
})

describe('isWeekend', () => {
  it('is true only for Saturday and Sunday', () => {
    expect(isWeekend('2026-07-25')).toBe(true) // Sat
    expect(isWeekend('2026-07-26')).toBe(true) // Sun
    expect(isWeekend('2026-07-24')).toBe(false) // Fri
    expect(isWeekend('2026-07-27')).toBe(false) // Mon
  })

  it('does NOT flag exchange holidays — those are the server calendar’s job', () => {
    // 2026-07-03 is the observed Independence Day holiday (a Friday). The client
    // deliberately reports it as a normal weekday rather than duplicating a
    // holiday list that would drift from Trading::Calendar.
    expect(isWeekend('2026-07-03')).toBe(false)
  })

  it('is false for malformed input', () => {
    expect(isWeekend('nonsense')).toBe(false)
  })

  it('does not slip a day across a year boundary', () => {
    expect(isWeekend('2026-01-01')).toBe(false) // Thursday
    expect(isWeekend('2025-12-31')).toBe(false) // Wednesday
  })
})

describe('marketClosedNotice', () => {
  it('explains a weekend date and names the day', () => {
    const notice = marketClosedNotice('2026-07-25')
    expect(notice).toContain('Saturday')
    expect(notice).toContain('next trading day')
  })

  it('is null on a weekday, so the form shows no notice', () => {
    expect(marketClosedNotice('2026-07-24')).toBeNull()
  })

  it('promises no specific effective date (a Monday holiday would falsify it)', () => {
    const notice = marketClosedNotice('2026-07-26') ?? ''
    expect(notice).not.toMatch(/\d{4}-\d{2}-\d{2}/)
    expect(notice).not.toMatch(/Monday/)
  })

  it('frames the transaction as accepted, not rejected', () => {
    expect(marketClosedNotice('2026-07-25')).toContain('recorded')
  })
})

describe('todayIso', () => {
  it('formats as YYYY-MM-DD', () => {
    expect(todayIso(new Date('2026-07-24T16:00:00Z'))).toBe('2026-07-24')
  })

  it('uses the ET calendar date, not UTC', () => {
    // 03:30 UTC on the 25th is 23:30 ET on the 24th — still the 24th in New York.
    expect(todayIso(new Date('2026-07-25T03:30:00Z'))).toBe('2026-07-24')
    // 13:00 UTC is 09:00 ET the same day.
    expect(todayIso(new Date('2026-07-25T13:00:00Z'))).toBe('2026-07-25')
  })
})

describe('picker date round-trip', () => {
  it('preserves the calendar date in both directions', () => {
    for (const iso of ['2026-07-24', '2026-01-01', '2026-12-31', '2024-02-29']) {
      expect(pickerDateToIso(isoToPickerDate(iso)), iso).toBe(iso)
    }
  })

  it('builds a local-midnight Date so the picker highlights the intended day', () => {
    const date = isoToPickerDate('2026-07-24')
    expect(date?.getFullYear()).toBe(2026)
    expect(date?.getMonth()).toBe(6)
    expect(date?.getDate()).toBe(24)
    expect(date?.getHours()).toBe(0)
  })

  it('returns null for missing or malformed values', () => {
    expect(isoToPickerDate(null)).toBeNull()
    expect(isoToPickerDate(undefined)).toBeNull()
    expect(isoToPickerDate('')).toBeNull()
    expect(isoToPickerDate('2026-7-4')).toBeNull()
    expect(pickerDateToIso(null)).toBeNull()
    expect(pickerDateToIso(new Date('nope'))).toBeNull()
  })
})
