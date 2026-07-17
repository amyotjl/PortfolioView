# As-built API response shapes (frozen contract, tester-verified)

Recorded live by the M4 verification agents against the running API. These are the
source of truth for the frontend zod schemas (`frontend/src/types/`). Conventions:

- **Money, shares, percentages, weights are JSON *strings*** (BigDecimal end-to-end; no Float).
- Dates are ISO `YYYY-MM-DD`; timestamps are ISO-8601 UTC (`...Z`).
- Every error uses one envelope: `{"error": {"code": string, "message": string, "details": object}}` —
  `details` is `{}` except on 422 where it maps `{field: [messages]}` (position violations use `base`).
  Codes in use: `unauthenticated`, `invalid_credentials`, `invalid_csrf_token`, `rate_limited`,
  `not_found`, `price_unavailable`, `validation_failed`, `invalid_invite_code`, `unprocessable_entity`.
- CSRF: readable `XSRF-TOKEN` cookie echoed as `X-XSRF-TOKEN` header on every non-GET.
- Cross-user and nonexistent resources return **byte-identical** 404 envelopes (no existence leak).

## Auth
- `GET /api/v1/session` → `{"user": {"id": number, "email_address": string}}`; 401 envelope when signed out (still sets the XSRF cookie).
- `POST /api/v1/session` → 201 same shape + HttpOnly session cookie; `DELETE` → 204.
- `POST /api/v1/registration` (requires `invite_code`) → 201 same shape + session cookie.

## Reference data
- `GET /api/v1/instruments/search?q=` → `{"instruments": [{symbol, name, exchange, asset_type, currency}]}` — no id (transactions POST by symbol); max 20; ordered exact > prefix > name.
- `GET /api/v1/instruments/:id/price?date=` → `{"price": {"instrument_id": number, "date": ISO, "close": string}}` — `date` is the trading day actually used (≤ requested); before-history → 404 `price_unavailable`.
- `GET /api/v1/benchmarks` → `{"benchmarks": [{id: number, name, symbol}]}` (seed order).

## Portfolios
- Single: `{"portfolio": {id, name, benchmark_id: number|null, series_version: number, created_at, updated_at}}`; index `{"portfolios": [...]}`.

## Transactions
- Single: `{"transaction": {id, portfolio_id, instrument_id, symbol, side: "buy"|"sell", kind: "normal"|"dividend_reinvestment", shares: string, price: string, fees: string, executed_on: ISO, notes: string|null, recurring_transaction_id: number|null, created_at, updated_at}}`.
- Index: `{"transactions": [...], "meta": {page, per_page, total_count, total_pages}}` (default 50/page, max 100, most-recent-first).

## Recurring transactions
- Single: `{"recurring_transaction": {id, portfolio_id, instrument_id, symbol, side: "buy", amount_type: "dollars"|"shares", dollar_amount: string|null, share_amount: string|null, frequency, anchor_on, next_run_on, end_on: ISO|null, active: boolean, paused_reason: string|null, consecutive_skips: number, created_at, updated_at}}`; index `{"recurring_transactions": [...]}`.
- `POST .../preview` → `{"preview": {"run_dates": [{scheduled_for: ISO, execution_on: ISO|null}]}}` (3 slots; nothing persisted).

## Holdings pre-flight
- `GET .../holdings?instrument_id=&as_of=` → `{"holding": {instrument_id: number, as_of: ISO (echoes request), shares: string}}` — shares computed at the last trading day ≤ as_of; unknown/flat → `"0.0"` with 200.

## Analytics
- `GET .../candles?from&to&benchmark=true` → **bare top-level object** (no wrapper key):
  ```jsonc
  { "candles":   [{ "t": ISO, "o": str, "h": str, "l": str, "c": str }],
    "benchmark": { "symbol": str, "values": [{ "t": ISO, "v": str }] } | null,   // LINE, never candles
    "flows":     [{ "t": ISO, "net": str, "items": [{ "ticker": str, "kind": "buy"|"sell", "amount": str }] }],
    "drawdown":  [{ "t": ISO, "v": str }],   // fraction, 8dp, from ALL-TIME peak
    "meta": { "partial": bool, "filled_dates": ISO[], "benchmark_clamped": bool, "approximation": str } }
  ```
  Notes: flow `kind` is the trade side (DRIP is excluded from flows entirely); `benchmark_clamped` is the OR of over-withdrawal and short-history clamps; `net`/`amount` signed (buy +, sell −); `from`/`to` optional (inception → last trading day); malformed date → 422 on that field.
- `GET .../summary` → `{"summary": {current_value: str, net_deposits: str, total_return: str, total_return_pct: str|null, benchmark_return_pct: str|null, vs_benchmark_edge_pct: str|null, max_drawdown_pct: str, as_of: ISO|null}}` (pcts are fractions, 6dp; null when net_deposits ≤ 0 / no benchmark).
- `GET .../allocations` → `{"allocations": {as_of: ISO|null, total_value: str, by_instrument: [{instrument_id: number, symbol: str|null, value: str, weight: str}], by_sector: [{sector: str, value: str, weight: str}]}}` — largest-first, weights sum to 1, sectorless instruments bucket under `"ETF / Fund"`.

## Known envelope inconsistency (deliberate, don't "fix" in zod)
`/candles` is a bare object; `/summary` and `/allocations` are wrapped. Model exactly as-built.
