import { beforeEach, describe, expect, it, vi } from 'vitest'
import { computed, shallowRef } from 'vue'
import { render, screen, waitFor } from '@testing-library/vue'
import { fireEvent } from '@testing-library/dom'
import PrimeVue from 'primevue/config'
import { ApiError } from '@/api/client'
import { syncStatusResponseSchema, syncTriggerResponseSchema } from '@/types'
import type { SyncStatusSnapshot, SyncTriggerResult } from '@/types'

/**
 * INDEPENDENT TESTER GATE for issue #57 — written from scratch, not derived from
 * the shipped SyncCard.spec.ts.
 *
 * The shipped spec stubs `primevue/button` with a template that hard-codes
 * `:disabled="loading || disabled"` — i.e. it asserts the very behaviour its own
 * stub supplies. Every test in THIS file mounts the REAL unstyled PrimeVue
 * Button and Tag (`global.plugins`, exactly as main.ts configures them), so the
 * "disabled + spinner" acceptance criterion is measured against the component
 * that actually ships.
 *
 * Payloads are byte-for-byte live captures taken through real HTTP from a real
 * session against `pv_t57` (see the issue evidence comment).
 */

const snapshot = shallowRef<SyncStatusSnapshot | null>(null)
const queryStatus = shallowRef<'pending' | 'success' | 'error'>('success')
const isLoading = shallowRef(false)
const mutateAsync = vi.fn<() => Promise<SyncTriggerResult>>()
const refetch = vi.fn()
const toastAdd = vi.fn()

vi.mock('@/composables/useSync', () => ({
  SYNC_KEY: ['sync'],
  useSyncStatusQuery: () => ({
    sync: computed(() => snapshot.value),
    status: queryStatus,
    refetch,
  }),
  useTriggerSync: () => ({ mutateAsync, isLoading }),
}))

vi.mock('primevue/usetoast', () => ({ useToast: () => ({ add: toastAdd }) }))

async function mount() {
  const SyncCard = (await import('./SyncCard.vue')).default
  return render(SyncCard, { global: { plugins: [[PrimeVue, { unstyled: true }]] } })
}

/** Live: GET /api/v1/sync, populated cache, nothing behind. */
const LIVE_WARM = JSON.parse(
  '{"sync":{"latest_price_on":"2026-07-30","last_trading_day":"2026-07-30","stale":false,"instruments_behind":0,"pending":false,"requested_at":null}}',
)
/** Live: one referenced instrument lags while SPY holds the MAX up. */
const LIVE_BEHIND = JSON.parse(
  '{"sync":{"latest_price_on":"2026-07-30","last_trading_day":"2026-07-30","stale":false,"instruments_behind":1,"pending":false,"requested_at":null}}',
)
/** Live: fresh database — BOTH dates null together, stale true. */
const LIVE_FRESH = JSON.parse(
  '{"sync":{"latest_price_on":null,"last_trading_day":null,"stale":true,"instruments_behind":3,"pending":false,"requested_at":null}}',
)
/** Live: the 10-minute claim lease held. */
const LIVE_PENDING = JSON.parse(
  '{"sync":{"latest_price_on":null,"last_trading_day":null,"stale":true,"instruments_behind":3,"pending":true,"requested_at":"2026-07-31T02:53:39Z"}}',
)
const LIVE_POST_ENQUEUED = JSON.parse(
  '{"sync":{"status":"enqueued","requested_at":"2026-07-31T02:53:39Z"}}',
)
const LIVE_POST_DEDUPED = JSON.parse(
  '{"sync":{"status":"already_pending","requested_at":"2026-07-31T02:53:39Z"}}',
)

function parseLive(payload: unknown): SyncStatusSnapshot {
  return syncStatusResponseSchema.parse(payload).sync
}

describe('gate #57 — live captures parse (both verbs, fresh and warm)', () => {
  it('GET accepts every live snapshot shape, including the fresh-database nulls', () => {
    expect(parseLive(LIVE_WARM).instruments_behind).toBe(0)
    expect(parseLive(LIVE_BEHIND).instruments_behind).toBe(1)

    const fresh = parseLive(LIVE_FRESH)
    expect(fresh.latest_price_on).toBeNull()
    expect(fresh.last_trading_day).toBeNull()
    expect(fresh.stale).toBe(true)

    const pending = parseLive(LIVE_PENDING)
    expect(pending.pending).toBe(true)
    expect(pending.requested_at).toBe('2026-07-31T02:53:39Z')
  })

  it('POST parses under its OWN schema and is rejected by the GET one', () => {
    expect(syncTriggerResponseSchema.parse(LIVE_POST_ENQUEUED).sync.status).toBe('enqueued')
    // The deduped 202 echoes the FIRST claim's time, verified live.
    expect(syncTriggerResponseSchema.parse(LIVE_POST_DEDUPED).sync.requested_at).toBe(
      '2026-07-31T02:53:39Z',
    )
    expect(() => syncStatusResponseSchema.parse(LIVE_POST_ENQUEUED)).toThrow()
  })
})

describe('gate #57 — SyncCard against the REAL PrimeVue Button', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    snapshot.value = parseLive(LIVE_WARM)
    queryStatus.value = 'success'
    isLoading.value = false
    mutateAsync.mockResolvedValue(syncTriggerResponseSchema.parse(LIVE_POST_ENQUEUED).sync)
  })

  it('AC1: exposes a control whose accessible name is exactly "Sync now"', async () => {
    await mount()

    // exact:true equivalent — testing-library string matching is exact by
    // default, so a substring match ("Sync now and more") would NOT satisfy this.
    const button = screen.getByRole('button', { name: 'Sync now' })
    expect(button.tagName).toBe('BUTTON')
    // "Check again" is a separate control and must not be confused for it.
    expect(screen.getByRole('button', { name: 'Check again' })).not.toBe(button)
    expect(screen.getAllByRole('button')).toHaveLength(2)
  })

  it('AC2: the REAL Button is genuinely disabled and renders a spinner in flight', async () => {
    isLoading.value = true
    await mount()

    const button = screen.getByRole('button', { name: 'Syncing…' })
    // Not the shipped spec's stub: this is primevue/button deciding.
    expect((button as HTMLButtonElement).disabled).toBe(true)
    expect(button.getAttribute('aria-busy')).toBe('true')

    // The spinner is ours (unstyled PrimeVue ships no spinner CSS) and must be
    // hidden from AT, since the state is already in the label + aria-busy.
    const spinner = button.querySelector('.animate-spin')
    expect(spinner).not.toBeNull()
    expect(spinner?.getAttribute('aria-hidden')).toBe('true')
  })

  it('AC2: a server-reported lease disables it too, on page load, with no click', async () => {
    snapshot.value = parseLive(LIVE_PENDING)
    await mount()

    expect((screen.getByRole('button', { name: 'Syncing…' }) as HTMLButtonElement).disabled).toBe(
      true,
    )
    expect(screen.getByText('A sync was already requested at Jul 30, 10:53 PM EDT.')).toBeTruthy()
  })

  it('AC2: a double-click fires exactly ONE POST', async () => {
    // The disable is what debounces: without it the second click re-enters
    // syncNow while the first await is still pending.
    let resolve: (value: SyncTriggerResult) => void = () => {}
    mutateAsync.mockImplementation(() => {
      isLoading.value = true
      return new Promise<SyncTriggerResult>((r) => {
        resolve = r
      })
    })

    await mount()
    const button = screen.getByRole('button', { name: 'Sync now' })
    await fireEvent.click(button)
    await fireEvent.click(button)
    await fireEvent.click(button)

    expect(mutateAsync).toHaveBeenCalledTimes(1)
    resolve(syncTriggerResponseSchema.parse(LIVE_POST_ENQUEUED).sync)
  })

  it('AC3: a 500 surfaces the envelope message and leaves the card intact', async () => {
    mutateAsync.mockRejectedValue(
      new ApiError({
        status: 500,
        code: 'internal_error',
        message: 'Something went wrong on our end.',
        details: {},
      }),
    )
    await mount()
    await fireEvent.click(screen.getByRole('button', { name: 'Sync now' }))

    await waitFor(() => expect(screen.getByRole('alert')).toBeTruthy())
    expect(screen.getByRole('alert').textContent).toContain('Something went wrong on our end.')
    expect(toastAdd.mock.calls[0][0]).toMatchObject({ severity: 'error' })
    // Freshness hint survives, and the button is usable again.
    expect(screen.getByText('Prices are current through Jul 30, 2026.')).toBeTruthy()
    expect(
      (screen.getByRole('button', { name: 'Sync now' }) as HTMLButtonElement).disabled,
    ).toBe(false)
  })

  it('AC3: a bare network failure (not an ApiError) degrades to the connection banner', async () => {
    mutateAsync.mockRejectedValue(new TypeError('Failed to fetch'))
    await mount()
    await fireEvent.click(screen.getByRole('button', { name: 'Sync now' }))

    await waitFor(() => expect(screen.getByRole('alert')).toBeTruthy())
    expect(screen.getByRole('alert').textContent).toContain('Could not reach the server')
  })

  it('AC3: a 401 does not double-report — the client already routed to /login', async () => {
    // The fetch client's unauthorized handler redirects; the rejection still
    // lands here and must render copy, not a stack trace or a blank card.
    mutateAsync.mockRejectedValue(
      new ApiError({
        status: 401,
        code: 'unauthenticated',
        message: 'You must be signed in.',
        details: {},
      }),
    )
    await mount()
    await fireEvent.click(screen.getByRole('button', { name: 'Sync now' }))

    await waitFor(() => expect(screen.getByRole('alert')).toBeTruthy())
    // Verbatim from the live 401 capture.
    expect(screen.getByRole('alert').textContent).toContain('You must be signed in.')
  })

  it('AC4: the freshness hint names the through-date and is in a live region', async () => {
    await mount()

    const region = screen.getByRole('status')
    expect(region.textContent).toContain('Prices are current through Jul 30, 2026.')
    expect(screen.getByText('Up to date')).toBeTruthy()
  })

  it('AC4: a fresh database says "Never synced" and invents no date', async () => {
    snapshot.value = parseLive(LIVE_FRESH)
    await mount()

    const region = screen.getByRole('status')
    expect(region.textContent).toContain('No price data yet')
    expect(region.textContent).not.toMatch(/\d{4}/)
    expect(screen.getByText('Never synced')).toBeTruthy()
    // Still actionable — this is exactly the state where a sync is needed.
    expect(
      (screen.getByRole('button', { name: 'Sync now' }) as HTMLButtonElement).disabled,
    ).toBe(false)
  })

  it('#59: instruments_behind renders at 1, is silent at 0, and survives a large count', async () => {
    const { unmount } = await mount()
    expect(screen.queryByText(/behind the rest of the cache/)).toBeNull() // live: 0
    unmount()

    snapshot.value = parseLive(LIVE_BEHIND)
    const second = await mount()
    expect(
      screen.getByText('1 symbol is behind the rest of the cache — a sync will try again.'),
    ).toBeTruthy()
    second.unmount()

    snapshot.value = { ...parseLive(LIVE_WARM), instruments_behind: 106253 }
    await mount()
    expect(
      screen.getByText('106253 symbols are behind the rest of the cache — a sync will try again.'),
    ).toBeTruthy()
  })

  it('offers "Check again" and it actually refetches', async () => {
    await mount()
    await fireEvent.click(screen.getByRole('button', { name: 'Check again' }))

    expect(refetch).toHaveBeenCalledTimes(1)
  })
})
