import { z } from 'zod'
import { parseResponse } from '@/types/parse'
import { errorEnvelopeSchema, type FieldErrors } from '@/types/common'

/**
 * Typed fetch wrapper for the same-origin Rails JSON API (see docs/PLAN.md).
 *
 * - Relative base `/api/v1` (the Vite dev proxy / prod SPA mount handle routing).
 * - `credentials: 'same-origin'` so the HttpOnly session cookie rides along.
 * - CSRF: the readable `XSRF-TOKEN` cookie is echoed as `X-XSRF-TOKEN` on every
 *   non-GET request.
 * - One error envelope `{ error: { code, message, details } }` -> typed `ApiError`.
 * - 401 -> invoke the registered unauthorized handler (login redirect), then throw.
 * - 429 -> honor `Retry-After` for GETs only (idempotent); mutations throw so we
 *   never silently double-submit.
 * - Every JSON body is validated through its zod schema at this boundary.
 */

const API_BASE = '/api/v1'
const XSRF_COOKIE = 'XSRF-TOKEN'
const XSRF_HEADER = 'X-XSRF-TOKEN'
/** Cap an over-eager Retry-After so a hostile/misconfigured header can't hang the UI. */
const MAX_RETRY_AFTER_MS = 60_000

export type HttpMethod = 'GET' | 'POST' | 'PATCH' | 'PUT' | 'DELETE'

export type QueryValue = string | number | boolean | null | undefined
export type QueryParams = Record<string, QueryValue>

export interface RequestConfig {
  query?: QueryParams
  signal?: AbortSignal
  /** Defaults to true; set false for the /session bootstrap so a signed-out probe doesn't redirect. */
  redirectOnUnauthorized?: boolean
}

interface InternalConfig extends RequestConfig {
  method: HttpMethod
  body?: unknown
  schema?: z.ZodType
}

interface ApiErrorInit {
  status: number
  code: string
  message: string
  details: FieldErrors
  retryAfter?: number
}

/** Normalized API failure. `details` carries the 422 field -> messages map. */
export class ApiError extends Error {
  readonly status: number
  readonly code: string
  readonly details: FieldErrors
  readonly retryAfter?: number

  constructor(init: ApiErrorInit) {
    super(init.message)
    this.name = 'ApiError'
    this.status = init.status
    this.code = init.code
    this.details = init.details
    this.retryAfter = init.retryAfter
  }

  /** True for validation failures whose `details` should map onto form fields. */
  get isValidationError(): boolean {
    return this.status === 422 || this.code === 'validation_failed'
  }

  /** Messages for a single field (whole-record errors live under `base`). */
  fieldMessages(field: string): string[] {
    return this.details[field] ?? []
  }
}

// --- Unauthorized handling ---------------------------------------------------

export type UnauthorizedHandler = () => void

let unauthorizedHandler: UnauthorizedHandler = () => {
  if (typeof window !== 'undefined' && window.location.pathname !== '/login') {
    window.location.assign('/login')
  }
}

/** Wire the SPA-aware handler (clear auth store + router.push) from main.ts. */
export function setUnauthorizedHandler(handler: UnauthorizedHandler): void {
  unauthorizedHandler = handler
}

// --- Helpers -----------------------------------------------------------------

function readXsrfToken(): string | null {
  if (typeof document === 'undefined') return null
  const match = document.cookie.match(new RegExp(`(?:^|;\\s*)${XSRF_COOKIE}=([^;]*)`))
  return match ? decodeURIComponent(match[1]) : null
}

function buildUrl(path: string, query?: QueryParams): string {
  const url = path.startsWith('/') ? `${API_BASE}${path}` : `${API_BASE}/${path}`
  if (!query) return url
  const params = new URLSearchParams()
  for (const [key, value] of Object.entries(query)) {
    if (value === null || value === undefined) continue
    params.append(key, String(value))
  }
  const qs = params.toString()
  return qs ? `${url}?${qs}` : url
}

/** Retry-After may be delta-seconds or an HTTP-date. Returns a clamped ms delay. */
function parseRetryAfterMs(header: string | null): number | null {
  if (!header) return null
  const seconds = Number(header)
  if (Number.isFinite(seconds)) {
    return Math.min(Math.max(seconds, 0) * 1000, MAX_RETRY_AFTER_MS)
  }
  const dateMs = Date.parse(header)
  if (Number.isNaN(dateMs)) return null
  return Math.min(Math.max(dateMs - Date.now(), 0), MAX_RETRY_AFTER_MS)
}

function delay(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms))
}

async function toApiError(response: Response): Promise<ApiError> {
  let code = 'unknown_error'
  let message = response.statusText || 'Request failed'
  let details: FieldErrors = {}

  try {
    const body = await response.json()
    const parsed = errorEnvelopeSchema.safeParse(body)
    if (parsed.success) {
      code = parsed.data.error.code
      message = parsed.data.error.message
      details = parsed.data.error.details
    }
  } catch {
    // Non-JSON or empty body: keep the status-derived defaults.
  }

  const retryAfterMs = parseRetryAfterMs(response.headers.get('Retry-After'))
  return new ApiError({
    status: response.status,
    code,
    message,
    details,
    retryAfter: retryAfterMs === null ? undefined : Math.round(retryAfterMs / 1000),
  })
}

// --- Core request ------------------------------------------------------------

async function request(path: string, config: InternalConfig): Promise<unknown> {
  const { method, body, schema, query, signal, redirectOnUnauthorized = true } = config
  const url = buildUrl(path, query)

  const headers = new Headers({ Accept: 'application/json' })
  let serializedBody: string | undefined
  if (body !== undefined) {
    headers.set('Content-Type', 'application/json')
    serializedBody = JSON.stringify(body)
  }
  if (method !== 'GET') {
    const token = readXsrfToken()
    if (token) headers.set(XSRF_HEADER, token)
  }

  let retriedForRateLimit = false
  // Loop only to service a single GET Retry-After backoff; every other path returns.
  for (;;) {
    const response = await fetch(url, {
      method,
      headers,
      body: serializedBody,
      credentials: 'same-origin',
      signal,
    })

    if (response.status === 429 && method === 'GET' && !retriedForRateLimit) {
      const retryMs = parseRetryAfterMs(response.headers.get('Retry-After'))
      if (retryMs !== null) {
        retriedForRateLimit = true
        await delay(retryMs)
        continue
      }
    }

    if (response.status === 401 && redirectOnUnauthorized) {
      unauthorizedHandler()
    }

    if (!response.ok) {
      throw await toApiError(response)
    }

    if (response.status === 204) return undefined
    const contentType = response.headers.get('Content-Type') ?? ''
    if (!contentType.includes('application/json')) return undefined

    const json = await response.json()
    return schema ? parseResponse(schema, json, `${method} ${path}`) : json
  }
}

// --- Public verbs (overloaded so a passed schema narrows the return type) ----

export function apiGet<S extends z.ZodType>(
  path: string,
  config: RequestConfig & { schema: S },
): Promise<z.infer<S>>
export function apiGet(path: string, config?: RequestConfig): Promise<unknown>
export function apiGet(
  path: string,
  config: RequestConfig & { schema?: z.ZodType } = {},
): Promise<unknown> {
  return request(path, { ...config, method: 'GET' })
}

export function apiPost<S extends z.ZodType>(
  path: string,
  body: unknown,
  config: RequestConfig & { schema: S },
): Promise<z.infer<S>>
export function apiPost(path: string, body?: unknown, config?: RequestConfig): Promise<unknown>
export function apiPost(
  path: string,
  body?: unknown,
  config: RequestConfig & { schema?: z.ZodType } = {},
): Promise<unknown> {
  return request(path, { ...config, method: 'POST', body })
}

export function apiPatch<S extends z.ZodType>(
  path: string,
  body: unknown,
  config: RequestConfig & { schema: S },
): Promise<z.infer<S>>
export function apiPatch(path: string, body?: unknown, config?: RequestConfig): Promise<unknown>
export function apiPatch(
  path: string,
  body?: unknown,
  config: RequestConfig & { schema?: z.ZodType } = {},
): Promise<unknown> {
  return request(path, { ...config, method: 'PATCH', body })
}

export function apiDelete<S extends z.ZodType>(
  path: string,
  config: RequestConfig & { schema: S },
): Promise<z.infer<S>>
export function apiDelete(path: string, config?: RequestConfig): Promise<unknown>
export function apiDelete(
  path: string,
  config: RequestConfig & { schema?: z.ZodType } = {},
): Promise<unknown> {
  return request(path, { ...config, method: 'DELETE' })
}

/** Convenience aggregate for `import { api } from '@/api/client'`. */
export const api = {
  get: apiGet,
  post: apiPost,
  patch: apiPatch,
  delete: apiDelete,
}
