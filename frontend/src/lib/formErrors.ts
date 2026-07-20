import { ApiError } from '@/api/client'

/**
 * Result of translating an API failure into something a vee-validate form can
 * render: a per-field message map (for `setErrors`) plus an optional form-level
 * banner message for anything that doesn't belong to a specific field.
 */
export interface MappedApiError {
  /** field name -> first message; only fields listed in `knownFields`. */
  fieldErrors: Record<string, string>
  /** A non-field message to show above the form, or null if fully field-mapped. */
  formMessage: string | null
}

const GENERIC_MESSAGE = 'Something went wrong. Please try again.'
const NETWORK_MESSAGE = 'Could not reach the server. Check your connection and try again.'

function rateLimitedMessage(retryAfter?: number): string {
  if (retryAfter && retryAfter > 0) {
    const unit = retryAfter === 1 ? 'second' : 'seconds'
    return `Too many attempts. Please wait ${retryAfter} ${unit} and try again.`
  }
  return 'Too many attempts. Please wait a moment and try again.'
}

/**
 * Map the one API error envelope onto a form (docs/PLAN.md § Error UX):
 * - `validation_failed` / any 422 (incl. `invalid_invite_code`, whose envelope
 *   already carries `details.invite_code`) -> per-field messages via `details`;
 *   any detail key not present in the form falls back to the form-level banner.
 * - `invalid_credentials` / `rate_limited` / everything else -> form-level banner.
 * - A non-`ApiError` (network/parse failure) -> a connection banner.
 *
 * Pure and dependency-free so it is unit-testable and reusable by every form
 * (login, register, portfolio create/edit).
 */
export function mapApiError(error: unknown, knownFields: readonly string[]): MappedApiError {
  if (!(error instanceof ApiError)) {
    return { fieldErrors: {}, formMessage: NETWORK_MESSAGE }
  }

  if (error.code === 'rate_limited' || error.status === 429) {
    return { fieldErrors: {}, formMessage: rateLimitedMessage(error.retryAfter) }
  }

  if (error.isValidationError) {
    const fieldErrors: Record<string, string> = {}
    const leftovers: string[] = []
    const known = new Set(knownFields)

    for (const [field, messages] of Object.entries(error.details)) {
      const first = messages[0]
      if (!first) continue
      if (known.has(field)) {
        fieldErrors[field] = first
      } else {
        // `base` (whole-record) and any field the form doesn't render.
        leftovers.push(first)
      }
    }

    const mappedAnything = Object.keys(fieldErrors).length > 0
    const formMessage = leftovers.length > 0 ? leftovers.join(' ') : mappedAnything ? null : error.message
    return { fieldErrors, formMessage }
  }

  // invalid_credentials, not_found, and any other coded failure: show the
  // server's human message at the form level.
  return { fieldErrors: {}, formMessage: error.message || GENERIC_MESSAGE }
}
