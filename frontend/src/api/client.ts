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

interface RawConfig {
  method: HttpMethod
  headers: Headers
  body?: BodyInit
  query?: QueryParams
  signal?: AbortSignal
  redirectOnUnauthorized?: boolean
}

/**
 * The shared network path: 429 backoff (GETs only), the 401 handler, and the
 * error-envelope throw. Returns the raw `Response` so callers can take it as
 * JSON (`request`) or as bytes (`apiDownload`).
 */
async function performFetch(path: string, config: RawConfig): Promise<Response> {
  const { method, headers, body, query, signal, redirectOnUnauthorized = true } = config
  const url = buildUrl(path, query)

  let retriedForRateLimit = false
  // Loop only to service a single GET Retry-After backoff; every other path returns.
  for (;;) {
    const response = await fetch(url, {
      method,
      headers,
      body,
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

    return response
  }
}

/** Every non-GET echoes the readable XSRF cookie back as a header. */
function withCsrf(headers: Headers, method: HttpMethod): Headers {
  if (method !== 'GET') {
    const token = readXsrfToken()
    if (token) headers.set(XSRF_HEADER, token)
  }
  return headers
}

async function request(path: string, config: InternalConfig): Promise<unknown> {
  const { method, body, schema, query, signal, redirectOnUnauthorized } = config

  const headers = withCsrf(new Headers({ Accept: 'application/json' }), method)
  let serializedBody: string | undefined
  if (body !== undefined) {
    headers.set('Content-Type', 'application/json')
    serializedBody = JSON.stringify(body)
  }

  const response = await performFetch(path, {
    method,
    headers,
    body: serializedBody,
    query,
    signal,
    redirectOnUnauthorized,
  })

  if (response.status === 204) return undefined
  const contentType = response.headers.get('Content-Type') ?? ''
  if (!contentType.includes('application/json')) return undefined

  const json = await response.json()
  return schema ? parseResponse(schema, json, `${method} ${path}`) : json
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

// --- File transfer (portfolio export/import, issue #64) ----------------------

export interface DownloadedFile {
  blob: Blob
  /** From Content-Disposition; the caller supplies a fallback. */
  filename: string
}

/**
 * Parse a filename out of Content-Disposition, preferring the RFC 5987
 * `filename*` form when present. Exported for unit testing.
 *
 * The result is treated as UNTRUSTED and reduced to a bare basename: it reaches
 * a download anchor, and a value like `../../evil.html` or a path separator must
 * never influence where the browser writes.
 */
export function filenameFromContentDisposition(header: string | null): string | null {
  if (!header) return null

  const extended = header.match(/filename\*\s*=\s*[^']*'[^']*'([^;]+)/i)
  const quoted = header.match(/filename\s*=\s*"([^"]*)"/i)
  const bare = header.match(/filename\s*=\s*([^;]+)/i)

  let raw: string | null = null
  if (extended) {
    try {
      raw = decodeURIComponent(extended[1].trim())
    } catch {
      raw = extended[1].trim()
    }
  } else if (quoted) {
    raw = quoted[1]
  } else if (bare) {
    raw = bare[1].trim()
  }
  if (raw === null) return null

  const basename = raw.split(/[\\/]/).pop()?.trim() ?? ''
  return basename && basename !== '.' && basename !== '..' ? basename : null
}

/**
 * GET a response as a file. Shares the same auth/CSRF/401/error handling as every
 * other call — which is exactly why this exists instead of pointing
 * `window.location` at the URL: a plain navigation would render the 401/422 JSON
 * envelope as a downloaded file instead of routing the user to /login.
 */
export async function apiDownload(
  path: string,
  fallbackFilename: string,
  config: RequestConfig = {},
): Promise<DownloadedFile> {
  const response = await performFetch(path, {
    method: 'GET',
    headers: new Headers({ Accept: 'application/json' }),
    query: config.query,
    signal: config.signal,
    redirectOnUnauthorized: config.redirectOnUnauthorized,
  })

  return {
    blob: await response.blob(),
    filename: filenameFromContentDisposition(response.headers.get('Content-Disposition')) ?? fallbackFilename,
  }
}

export function apiUpload<S extends z.ZodType>(
  path: string,
  formData: FormData,
  config: RequestConfig & { schema: S },
): Promise<z.infer<S>>
export function apiUpload(path: string, formData: FormData, config?: RequestConfig): Promise<unknown>
/**
 * POST multipart/form-data. Content-Type is deliberately NOT set: the browser
 * must generate it so it can append the multipart boundary, and setting it by
 * hand produces a body Rack cannot parse.
 */
export async function apiUpload(
  path: string,
  formData: FormData,
  config: RequestConfig & { schema?: z.ZodType } = {},
): Promise<unknown> {
  const response = await performFetch(path, {
    method: 'POST',
    headers: withCsrf(new Headers({ Accept: 'application/json' }), 'POST'),
    body: formData,
    query: config.query,
    signal: config.signal,
    redirectOnUnauthorized: config.redirectOnUnauthorized,
  })

  if (response.status === 204) return undefined
  const json = await response.json()
  return config.schema ? parseResponse(config.schema, json, `POST ${path}`) : json
}

/** Convenience aggregate for `import { api } from '@/api/client'`. */
export const api = {
  get: apiGet,
  post: apiPost,
  patch: apiPatch,
  delete: apiDelete,
  download: apiDownload,
  upload: apiUpload,
}
