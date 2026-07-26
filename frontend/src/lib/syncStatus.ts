import { formatDate, formatDateTime } from '@/lib/format'
import { SYNC_ALREADY_PENDING, SYNC_ENQUEUED } from '@/types'
import type { SyncStatusSnapshot, SyncTriggerResult } from '@/types'

/**
 * Presentation logic for the Settings "Sync now" card (issue #57). Pure and
 * DOM-free, following `lib/importSummary.ts`: which sentence a user reads for a
 * given `latest_price_on`/`stale`/`pending` combination is the whole feature, so
 * it is unit-tested rather than eyeballed in a template.
 */

/** How much attention the freshness state deserves. Never conveyed by color alone. */
export type FreshnessTone = 'ok' | 'attention' | 'unknown'

export interface FreshnessHint {
  tone: FreshnessTone
  /** Short badge label. */
  label: string
  /** Full sentence for the card body. */
  text: string
}

/**
 * The data-freshness hint. Four cases, exactly as specified:
 *
 * - `latest_price_on === null` -> nothing has ever been cached. This is the real
 *   state of a fresh database, not a hypothetical.
 * - `stale === false`          -> current through that date, nothing to do.
 * - `stale === true`           -> current through that date, but a sync is due.
 *
 * `pending` is deliberately NOT folded in here: an in-flight sync says nothing
 * about how fresh the cache is *right now*, and the two lines are rendered
 * together. See `alreadyRequestedMessage` for the pending copy.
 */
export function freshnessHint(sync: SyncStatusSnapshot): FreshnessHint {
  if (sync.latest_price_on === null) {
    return {
      tone: 'unknown',
      label: 'Never synced',
      text: 'No price data yet — run a sync to fetch prices.',
    }
  }

  const through = formatDate(sync.latest_price_on)

  if (sync.stale) {
    return {
      tone: 'attention',
      label: 'Sync needed',
      text: `Prices are current through ${through} — a sync is needed.`,
    }
  }

  return {
    tone: 'ok',
    label: 'Up to date',
    text: `Prices are current through ${through}.`,
  }
}

/**
 * Tag severity per tone, mirroring `importSummary.statusSeverity`. `ok` is
 * neutral chrome rather than gain-green: assets/main.css reserves up/down
 * strictly for data values.
 */
export function freshnessSeverity(tone: FreshnessTone): 'warn' | 'secondary' {
  return tone === 'ok' ? 'secondary' : 'warn'
}

/**
 * The one sentence used for BOTH pending paths — the `already_pending` POST
 * result and a `pending: true` snapshot on page load — because they are the same
 * fact: the 10-minute dedupe lease is held, and `requested_at` is when it was
 * claimed (which may predate this page view entirely; cron and the boot
 * catch-up claim the same lease).
 *
 * Deliberately NOT "a sync is currently running": the lease outlives the actual
 * fetches, so that wording becomes a lie the moment the job finishes.
 */
export function alreadyRequestedMessage(requestedAt: string | null): string {
  if (!requestedAt) return 'A sync was already requested.'
  return `A sync was already requested at ${formatDateTime(requestedAt)}.`
}

export interface SyncToastMessage {
  severity: 'success' | 'info' | 'error'
  summary: string
  detail: string
}

/**
 * Toast for a SUCCESSFUL trigger. Both documented outcomes are `202`s, so
 * neither is an error toast — `already_pending` is informational.
 *
 * An unrecognized `status` (the backend may grow one; that is why the schema
 * models it as a plain string) falls through to a neutral acknowledgement
 * instead of being misreported as a failure.
 */
export function triggerToast(result: SyncTriggerResult): SyncToastMessage {
  if (result.status === SYNC_ALREADY_PENDING) {
    return {
      severity: 'info',
      summary: 'Sync already requested',
      detail: alreadyRequestedMessage(result.requested_at),
    }
  }

  if (result.status === SYNC_ENQUEUED) {
    return {
      severity: 'success',
      summary: 'Sync started',
      detail: 'Fetching the latest prices in the background.',
    }
  }

  return {
    severity: 'info',
    summary: 'Sync requested',
    detail: `The server reported status “${result.status}”.`,
  }
}

/** Toast for a FAILED trigger. `message` is the envelope message via `mapApiError`. */
export function triggerFailureToast(message: string | null): SyncToastMessage {
  return {
    severity: 'error',
    summary: 'Sync could not be started',
    detail: message ?? 'Something went wrong. Please try again.',
  }
}
