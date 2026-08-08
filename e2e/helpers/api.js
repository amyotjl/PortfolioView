/**
 * API helpers for e2e setup.
 *
 * Per the testing-conventions skill, a spec builds everything EXCEPT the flow
 * under test through the API rather than by clicking. These helpers run in the
 * browser's own context (`page.request`) so they share its cookie jar — the
 * session the UI is using stays the session the API calls use.
 *
 * CSRF: every non-GET must echo the readable XSRF-TOKEN cookie as X-XSRF-TOKEN,
 * exactly as the SPA's fetch wrapper does (frontend/src/api/client.ts).
 */

/** Registration is rate-limited to 10 per 3 min, so specs must register sparingly. */
export const INVITE_CODE = process.env.INVITE_CODE ?? 'dev-invite-code'

/** Unique per run; the suite never reuses or cleans up accounts. */
export function uniqueEmail(prefix = 'e2e') {
  const stamp = `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`
  return `${prefix}-${stamp}@example.test`
}

export const TEST_PASSWORD = 'e2e-password-123'

async function xsrfToken(page) {
  const cookies = await page.context().cookies()
  const token = cookies.find((cookie) => cookie.name === 'XSRF-TOKEN')
  return token ? decodeURIComponent(token.value) : null
}

/**
 * GET /session to obtain the XSRF cookie. Answers 401 while signed out and still
 * sets the cookie — that 401 is expected, not a failure.
 */
export async function primeCsrf(page) {
  await page.request.get('/api/v1/session', { failOnStatusCode: false })
}

async function mutate(page, method, url, data) {
  const token = await xsrfToken(page)
  const response = await page.request.fetch(url, {
    method,
    data,
    headers: {
      'Content-Type': 'application/json',
      ...(token ? { 'X-XSRF-TOKEN': token } : {}),
    },
    failOnStatusCode: false,
  })

  if (!response.ok()) {
    // Surface the API's error envelope verbatim — a soft failure here would show
    // up later as a confusing selector timeout instead of the real cause.
    throw new Error(
      `${method} ${url} failed: ${response.status()} ${await response.text()}`,
    )
  }
  return response.status() === 204 ? null : response.json()
}

export async function createPortfolio(page, { name, benchmarkId = null }) {
  const body = await mutate(page, 'POST', '/api/v1/portfolios', {
    name,
    benchmark_id: benchmarkId,
  })
  return body.portfolio
}

export async function createTransaction(page, portfolioId, transaction) {
  const body = await mutate(
    page,
    'POST',
    `/api/v1/portfolios/${portfolioId}/transactions`,
    { kind: 'normal', fees: '0', notes: null, ...transaction },
  )
  return body.transaction
}

/**
 * Record a cash movement (#80).
 *
 * `amount` IS SIGNED — positive for a deposit, negative for a withdrawal. An
 * unsigned figure is a 422 on `amount`; the server refuses to guess a direction
 * from `kind` because `tax`/`fee` are genuinely ± under one kind name. The SPA's
 * form is unsigned and converts in `frontend/src/forms/cash.ts`.
 *
 * The response's `meta` carries the post-write balance, which is what a caller
 * asserts on rather than recomputing it.
 */
export async function createCashTransaction(page, portfolioId, cashTransaction) {
  const body = await mutate(
    page,
    'POST',
    `/api/v1/portfolios/${portfolioId}/cash_transactions`,
    { kind: 'deposit', notes: null, ...cashTransaction },
  )
  return body
}

/** Seeded benchmarks (SPY, VTI, QQQ…) in seed order. */
export async function fetchBenchmarks(page) {
  const response = await page.request.get('/api/v1/benchmarks')
  if (!response.ok()) throw new Error(`GET /benchmarks failed: ${response.status()}`)
  return (await response.json()).benchmarks
}

export async function benchmarkIdFor(page, symbol) {
  const benchmarks = await fetchBenchmarks(page)
  const match = benchmarks.find((benchmark) => benchmark.symbol === symbol)
  if (!match) {
    throw new Error(
      `benchmark ${symbol} is not seeded (have: ${benchmarks.map((b) => b.symbol).join(', ')})`,
    )
  }
  return match.id
}
