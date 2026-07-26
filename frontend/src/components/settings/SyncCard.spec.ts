import { beforeEach, describe, expect, it, vi } from 'vitest'
import { computed, shallowRef } from 'vue'
import { render, screen, waitFor } from '@testing-library/vue'
import { fireEvent } from '@testing-library/dom'
import { ApiError } from '@/api/client'
import type { SyncStatusSnapshot, SyncTriggerResult } from '@/types'

/**
 * The wiring the pure helpers cannot cover: which state disables the button, and
 * that a failed trigger neither throws nor blanks the card. The composables and
 * the toast service are stubbed — this is about SyncCard's own logic, not about
 * re-testing Pinia Colada.
 */

const snapshot = shallowRef<SyncStatusSnapshot | null>(null)
const queryStatus = shallowRef<'pending' | 'success' | 'error'>('success')
const isLoading = shallowRef(false)
const mutateAsync = vi.fn<() => Promise<SyncTriggerResult>>()
const toastAdd = vi.fn()

vi.mock('@/composables/useSync', () => ({
  SYNC_KEY: ['sync'],
  useSyncStatusQuery: () => ({
    sync: computed(() => snapshot.value),
    status: queryStatus,
    refetch: vi.fn(),
  }),
  useTriggerSync: () => ({ mutateAsync, isLoading }),
}))

vi.mock('primevue/usetoast', () => ({ useToast: () => ({ add: toastAdd }) }))

// Unstyled PrimeVue components need no theme context, but they do read the
// PrimeVue injection — stub them down to plain elements instead.
vi.mock('primevue/button', () => ({
  default: {
    props: ['label', 'loading', 'disabled', 'text', 'severity', 'pt'],
    template: '<button :disabled="loading || disabled">{{ label }}</button>',
  },
}))
vi.mock('primevue/tag', () => ({
  default: { props: ['value', 'severity', 'pt'], template: '<span>{{ value }}</span>' },
}))

async function mount() {
  const SyncCard = (await import('./SyncCard.vue')).default
  return render(SyncCard)
}

function status(overrides: Partial<SyncStatusSnapshot> = {}): SyncStatusSnapshot {
  return {
    latest_price_on: '2026-07-24',
    last_trading_day: '2026-07-24',
    stale: true,
    pending: false,
    requested_at: null,
    ...overrides,
  }
}

describe('SyncCard', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    snapshot.value = status()
    queryStatus.value = 'success'
    isLoading.value = false
    mutateAsync.mockResolvedValue({ status: 'enqueued', requested_at: '2026-07-26T17:42:02Z' })
  })

  it('renders the freshness hint and an enabled button', async () => {
    await mount()

    expect(screen.getByText('Prices are current through Jul 24, 2026 — a sync is needed.')).toBeTruthy()
    expect(screen.getByRole('button', { name: 'Sync now' }).hasAttribute('disabled')).toBe(false)
  })

  it('shows the in-flight state ON PAGE LOAD when the server reports a held claim', async () => {
    // Not only after a click: cron, the boot catch-up, or another tab may hold
    // the lease before this page was ever opened.
    snapshot.value = status({ pending: true, requested_at: '2026-07-26T17:42:02Z' })
    await mount()

    expect(screen.getByRole('button', { name: 'Syncing…' }).hasAttribute('disabled')).toBe(true)
    expect(screen.getByText('A sync was already requested at Jul 26, 1:42 PM EDT.')).toBeTruthy()
  })

  it('toasts a success on enqueued', async () => {
    await mount()
    await fireEvent.click(screen.getByRole('button', { name: 'Sync now' }))

    await waitFor(() => expect(toastAdd).toHaveBeenCalled())
    expect(toastAdd.mock.calls[0][0]).toMatchObject({ severity: 'success', summary: 'Sync started' })
  })

  it('treats already_pending as information, not a failure', async () => {
    mutateAsync.mockResolvedValue({ status: 'already_pending', requested_at: '2026-07-26T17:42:02Z' })
    await mount()
    await fireEvent.click(screen.getByRole('button', { name: 'Sync now' }))

    await waitFor(() => expect(toastAdd).toHaveBeenCalled())
    expect(toastAdd.mock.calls[0][0].severity).toBe('info')
    // And nothing is pinned to the page as an error.
    expect(screen.queryByRole('alert')).toBeNull()
  })

  it('surfaces an envelope failure without breaking the card', async () => {
    mutateAsync.mockRejectedValue(
      new ApiError({
        status: 403,
        code: 'invalid_csrf_token',
        message: 'CSRF token missing or invalid.',
        details: {},
      }),
    )
    await mount()
    await fireEvent.click(screen.getByRole('button', { name: 'Sync now' }))

    await waitFor(() => expect(screen.getByRole('alert')).toBeTruthy())
    expect(screen.getByRole('alert').textContent).toContain('CSRF token missing or invalid.')
    expect(toastAdd.mock.calls[0][0].severity).toBe('error')
    // The hint is still there and the button is usable again.
    expect(screen.getByText('Prices are current through Jul 24, 2026 — a sync is needed.')).toBeTruthy()
    expect(screen.getByRole('button', { name: 'Sync now' }).hasAttribute('disabled')).toBe(false)
  })

  it('offers the trigger even when the freshness snapshot could not be loaded', async () => {
    queryStatus.value = 'error'
    snapshot.value = null
    await mount()

    expect(screen.getByText(/Couldn’t check when prices were last updated/)).toBeTruthy()
    expect(screen.getByRole('button', { name: 'Sync now' }).hasAttribute('disabled')).toBe(false)
  })
})
