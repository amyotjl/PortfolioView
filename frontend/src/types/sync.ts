import { z } from 'zod'
import { IsoDate, IsoDateTime } from './common'

/**
 * Price-cache sync (issues #56/#57, docs/API_SHAPES.md § Sync status / Sync triggers).
 *
 * TWO schemas, not one. `sync` wraps a DIFFERENT key set on GET than on POST:
 * GET is a state snapshot (5 keys), POST is an action result (2 keys). That
 * asymmetry is as-built and deliberate — POST's shape was frozen and coded
 * against before GET existed — so it is mirrored here rather than unified.
 */

/**
 * GET /api/v1/sync — the GLOBAL freshness snapshot (not portfolio-scoped, and
 * deliberately not `/summary`'s `as_of`, which is null for a portfolio with no
 * price coverage and would read as "never synced").
 *
 * NOT `.strict()`, on purpose: the backend is adding further fields (an
 * `instruments_behind` count) and an unknown key must pass through harmlessly
 * rather than fail the parse and blank the card.
 */
export const syncStatusSchema = z.object({
  /** MAX(latest_price_on) over referenced instruments. Null on a FRESH DATABASE. */
  latest_price_on: IsoDate.nullable(),
  /** Trading::Calendar.last_day. Null together with `latest_price_on`, never alone. */
  last_trading_day: IsoDate.nullable(),
  /**
   * Weekend-aware, deliberately NOT holiday-aware (the app has no holiday table
   * by design): on the ~9 US market holidays a year this reads true while the
   * cache is current. Accepted — a false "stale" costs one no-op sync. Do not
   * add holiday handling client-side.
   */
  stale: z.boolean(),
  /** True while a sync claim (10-minute lease) is held right now. */
  pending: z.boolean(),
  /** When the pending sync was claimed. Null iff `pending` is false. */
  requested_at: IsoDateTime.nullable(),
  /**
   * Landing in a concurrent backend change; absent today. Optional AND `.catch`
   * so neither its absence nor an unexpected type can fail the whole response.
   */
  instruments_behind: z.number().nullable().optional().catch(undefined),
})

export const syncStatusResponseSchema = z.object({
  sync: syncStatusSchema,
})

/**
 * POST /api/v1/sync — the action result. `202` in BOTH outcomes: `already_pending`
 * is a normal, informational answer (the 10-minute dedupe lease was already
 * held), never a failure.
 *
 * `status` is `z.string()`, not `z.enum`, for the same reason
 * `/portfolios/import`'s status is: a newer backend value must not throw and
 * blank the UI. `requested_at` is always present (the pending sync's claim time
 * on `already_pending`, this request's on `enqueued`).
 */
export const syncTriggerSchema = z.object({
  status: z.string(),
  requested_at: IsoDateTime,
})

export const syncTriggerResponseSchema = z.object({
  sync: syncTriggerSchema,
})

/** The two statuses the backend emits today. Compared as strings, never enumerated. */
export const SYNC_ENQUEUED = 'enqueued'
export const SYNC_ALREADY_PENDING = 'already_pending'

export type SyncStatusSnapshot = z.infer<typeof syncStatusSchema>
export type SyncStatusResponse = z.infer<typeof syncStatusResponseSchema>
export type SyncTriggerResult = z.infer<typeof syncTriggerSchema>
export type SyncTriggerResponse = z.infer<typeof syncTriggerResponseSchema>
