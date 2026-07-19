import { z } from 'zod'

/**
 * Shared primitives for the frozen API contract (see docs/API_SHAPES.md).
 *
 * MONEY / SHARES / PERCENT / WEIGHT ARE JSON STRINGS.
 * The backend uses BigDecimal end-to-end (numeric columns, no Float). Every
 * monetary value, share count, percentage and portfolio weight is serialized
 * as a JSON *string* so no precision is lost across the wire. We keep them as
 * `string` in TypeScript too: JS `number` is IEEE-754 and cannot represent
 * these values exactly. Formatting/aggregation happens through dedicated
 * decimal-aware helpers, never `parseFloat` + arithmetic. Modelling these as
 * `z.number()` would be a correctness bug, not a convenience.
 */
export const DecimalString = z.string()

/**
 * DATES STAY STRINGS.
 * Dates are ISO `YYYY-MM-DD`; timestamps are ISO-8601 UTC (`...Z`). We do NOT
 * `z.coerce` them into JS `Date` objects: a `Date` is an instant, but a trading
 * day is a calendar date in America/New_York — coercing to `Date` reintroduces
 * the timezone drift this app is built to avoid. Consumers keep the raw string
 * and format it with an explicit-timezone `Intl` helper.
 *
 * Format is intentionally NOT regex-validated: `IsoDate` vs `IsoDateTime` is a
 * documentation distinction only (both are `z.string()`), which also keeps the
 * schemas resilient to the date-vs-datetime ambiguity in a few contract fields.
 */
export const IsoDate = z.string()
export const IsoDateTime = z.string()

/**
 * The one error envelope used by every endpoint:
 *   { "error": { "code": string, "message": string, "details": object } }
 * `details` is `{}` except on 422, where it maps `{ field: [messages] }`
 * (position/whole-record violations bucket under the `base` key).
 */
export const KNOWN_ERROR_CODES = [
  'unauthenticated',
  'invalid_credentials',
  'invalid_csrf_token',
  'rate_limited',
  'not_found',
  'price_unavailable',
  'validation_failed',
  'invalid_invite_code',
  'unprocessable_entity',
] as const

export type KnownErrorCode = (typeof KNOWN_ERROR_CODES)[number]

/**
 * `details` shape: field -> array of messages. An empty `{}` (non-422 errors)
 * parses cleanly as an empty record. `code` is a plain string (not an enum) so
 * a newly-introduced backend code never breaks response parsing.
 */
export const fieldErrorsSchema = z.record(z.string(), z.array(z.string()))

export const errorEnvelopeSchema = z.object({
  error: z.object({
    code: z.string(),
    message: z.string(),
    details: fieldErrorsSchema.default({}),
  }),
})

export type FieldErrors = z.infer<typeof fieldErrorsSchema>
export type ErrorEnvelope = z.infer<typeof errorEnvelopeSchema>
