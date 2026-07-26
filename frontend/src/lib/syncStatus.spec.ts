import { describe, expect, it } from 'vitest'
import {
  alreadyRequestedMessage,
  behindNotice,
  freshnessHint,
  freshnessSeverity,
  triggerFailureToast,
  triggerToast,
} from '@/lib/syncStatus'
import type { SyncStatusSnapshot, SyncTriggerResult } from '@/types'

/**
 * The Settings sync card is nothing BUT wording: which sentence a user reads for
 * a given `latest_price_on`/`stale`/`pending` combination is the whole feature.
 * Same reasoning as importSummary.spec.ts.
 */

function snapshot(overrides: Partial<SyncStatusSnapshot> = {}): SyncStatusSnapshot {
  return {
    latest_price_on: '2026-07-24',
    last_trading_day: '2026-07-24',
    stale: false,
    pending: false,
    requested_at: null,
    ...overrides,
  }
}

describe('freshnessHint', () => {
  it('reports the through-date when the cache is current', () => {
    const hint = freshnessHint(snapshot())

    expect(hint.tone).toBe('ok')
    expect(hint.label).toBe('Up to date')
    expect(hint.text).toBe('Prices are current through Jul 24, 2026.')
    // No call to action when there is nothing to do.
    expect(hint.text).not.toContain('sync is needed')
  })

  it('asks for a sync when the cache is stale, still naming the through-date', () => {
    const hint = freshnessHint(snapshot({ stale: true }))

    expect(hint.tone).toBe('attention')
    expect(hint.label).toBe('Sync needed')
    expect(hint.text).toBe('Prices are current through Jul 24, 2026 — a sync is needed.')
  })

  it('renders the fresh-database case: both dates null, stale true', () => {
    // Verified live against a fresh database, not hypothetical: `latest_price_on`
    // and `last_trading_day` are null together and `stale` is then true.
    const hint = freshnessHint(
      snapshot({ latest_price_on: null, last_trading_day: null, stale: true }),
    )

    expect(hint.tone).toBe('unknown')
    expect(hint.label).toBe('Never synced')
    expect(hint.text).toBe('No price data yet — run a sync to fetch prices.')
    // Must never invent a date it does not have.
    expect(hint.text).not.toMatch(/\d{4}/)
  })

  it('says "never synced", not "up to date", when there is no data and stale is false', () => {
    // Defensive: the null date wins over `stale`, so a hypothetical
    // stale=false/no-data snapshot can never read as a healthy cache.
    const hint = freshnessHint(snapshot({ latest_price_on: null, last_trading_day: null }))

    expect(hint.label).toBe('Never synced')
  })

  it('ignores `pending` — freshness and in-flight are separate lines', () => {
    const busy = snapshot({ pending: true, requested_at: '2026-07-26T17:42:02Z' })

    expect(freshnessHint(busy)).toEqual(freshnessHint(snapshot()))
  })

  it('formats the through-date in America/New_York, never a day early', () => {
    // A bare ISO date parsed as UTC midnight renders as the previous day west of
    // Greenwich; formatDate anchors at midday to prevent exactly that.
    expect(freshnessHint(snapshot({ latest_price_on: '2026-01-01' })).text).toBe(
      'Prices are current through Jan 1, 2026.',
    )
  })
})

describe('behindNotice', () => {
  it('says nothing when the field is absent (a backend predating #59)', () => {
    expect(behindNotice(snapshot())).toBeNull()
  })

  it('says nothing when nothing is behind', () => {
    expect(behindNotice(snapshot({ instruments_behind: 0 }))).toBeNull()
  })

  it('reports the state `stale` structurally cannot: current overall, one symbol behind', () => {
    const sync = snapshot({ stale: false, instruments_behind: 1 })

    expect(freshnessHint(sync).label).toBe('Up to date')
    expect(behindNotice(sync)).toBe('1 symbol is behind the rest of the cache — a sync will try again.')
  })

  it('pluralizes', () => {
    expect(behindNotice(snapshot({ instruments_behind: 4 }))).toBe(
      '4 symbols are behind the rest of the cache — a sync will try again.',
    )
  })

  it('stays silent on a value it cannot use', () => {
    // The schema's `.catch` turns an unexpected type into undefined; a null or a
    // negative must be equally harmless.
    expect(behindNotice(snapshot({ instruments_behind: null }))).toBeNull()
    expect(behindNotice(snapshot({ instruments_behind: undefined }))).toBeNull()
    expect(behindNotice(snapshot({ instruments_behind: -1 }))).toBeNull()
  })
})

describe('freshnessSeverity', () => {
  it('is neutral only when nothing needs doing', () => {
    expect(freshnessSeverity('ok')).toBe('secondary')
    expect(freshnessSeverity('attention')).toBe('warn')
    expect(freshnessSeverity('unknown')).toBe('warn')
  })
})

describe('alreadyRequestedMessage', () => {
  it('names the claim time in ET, with the zone spelled out', () => {
    expect(alreadyRequestedMessage('2026-07-26T17:42:02Z')).toBe(
      'A sync was already requested at Jul 26, 1:42 PM EDT.',
    )
  })

  it('never claims a sync is RUNNING — the lease outlives the work', () => {
    const message = alreadyRequestedMessage('2026-07-26T17:42:02Z')

    expect(message).not.toMatch(/running|in progress/i)
    expect(message).toContain('already requested')
  })

  it('degrades to a timeless sentence when the timestamp is missing', () => {
    expect(alreadyRequestedMessage(null)).toBe('A sync was already requested.')
  })
})

describe('triggerToast', () => {
  function result(overrides: Partial<SyncTriggerResult> = {}): SyncTriggerResult {
    return { status: 'enqueued', requested_at: '2026-07-26T17:42:02Z', ...overrides }
  }

  it('celebrates a fresh enqueue', () => {
    const toast = triggerToast(result())

    expect(toast.severity).toBe('success')
    expect(toast.summary).toBe('Sync started')
  })

  it('treats already_pending as INFORMATIONAL, never an error', () => {
    const toast = triggerToast(result({ status: 'already_pending' }))

    expect(toast.severity).toBe('info')
    expect(toast.summary).toBe('Sync already requested')
    // Same one sentence as the on-load pending notice.
    expect(toast.detail).toBe(alreadyRequestedMessage('2026-07-26T17:42:02Z'))
  })

  it('acknowledges an unknown future status without reporting a failure', () => {
    // The schema models `status` as a plain string precisely so this can happen.
    const toast = triggerToast(result({ status: 'throttled' }))

    expect(toast.severity).not.toBe('error')
    expect(toast.detail).toContain('throttled')
  })
})

describe('triggerFailureToast', () => {
  it('carries the envelope message through', () => {
    const toast = triggerFailureToast('Your session has expired.')

    expect(toast.severity).toBe('error')
    expect(toast.summary).toBe('Sync could not be started')
    expect(toast.detail).toBe('Your session has expired.')
  })

  it('falls back to generic copy when the envelope had nothing to say', () => {
    expect(triggerFailureToast(null).detail).toBe('Something went wrong. Please try again.')
  })
})
