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
- `GET /api/v1/instruments/search?q=` → `{"instruments": [{symbol, name: str|null, exchange: str|null, asset_type: str|null, currency: str|null}]}` — only `symbol` is non-null (the only NOT NULL column on `listed_instruments`; the serializer emits columns raw). The bulk Tiingo supported_tickers import has no name column, so `name` is null **unless enriched** — since #63, `Directory::EnrichNamesJob` backfills it from `instruments.name` (FMP) for symbols the user has touched, so coverage is partial and grows over time; treat it as `str|null` forever. `exchange`/`asset_type`/`currency` may also be null. No id (transactions POST by symbol); max 20.

Ordering (#63, extended by #71) is **six** tiers, then alphabetical: **match band** (exact symbol > symbol prefix > name-only) → **tradeable** (USD on a US exchange, i.e. rows `DirectoryResolver` would accept, before ones it would 422) → **live** (`end_date` within 180 days or NULL, before delisted) → **asset class** (equities/ETFs before mutual funds) → **symbol length** → **listing age** (`start_date` ascending, NULLs last).

The cap makes ordering a correctness concern, not a nicety: a weak sort silently truncates the row the user meant rather than returning a wrong one. Before #63, `MSF` never returned MSFT; before #71, `AA` never returned AAPL.

**Age sits after length deliberately.** Measured over 76 well-known tickers against the real 106k directory, 2-character coverage is 55/76 with no age tier, **64/76 with age before length — but that loses ARM, NET, RDDT and SOFI** (a 1998 ADR still carrying recent prices outranked the 2023 `ARM`), and **67/76 with age after length**, which loses only SOFI. 3-character coverage is 75/76 under all three. Don't reorder those two tiers without re-running that measurement.

Search costs **~13 ms** on the real directory (Seq Scan; an index cannot serve a `CASE` in `ORDER BY`). Unchanged by #63/#71, and the ticker AutoComplete debounces at 250 ms.
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
- `GET .../allocations` → `{"allocations": {as_of: ISO|null, total_value: str, by_instrument: [{instrument_id: number, symbol: str|null, sector: str, value: str, weight: str}], by_sector: [{sector: str, value: str, weight: str}]}}` — largest-first, weights sum to 1, sectorless instruments bucket under `"ETF / Fund"`. An instrument slice's `sector` is byte-identical to its `by_sector` label, so grouping `by_instrument` on it reproduces `by_sector` exactly — that join key is what makes the sector treemap's hierarchy derivable client-side (added in M8/#53; `by_sector` alone is a flat list and `instruments` isn't addressable from the frontend by id).

## Export / import (issue #64)
- `GET /api/v1/portfolios/export[?portfolio_ids[]=N]` → **not a JSON API response**: a
  `Content-Disposition: attachment` download, `application/json`, pretty-printed, filename
  `portfolioview-portfolios-<YYYYMMDD>-<HHMMSS>.json`. Scoped to the current user; unowned ids
  are simply absent (no existence leak). Body:
  ```jsonc
  { "format": "portfolioview.portfolios", "version": 1, "exported_at": ISO-8601-Z,
    "instruments": [{ symbol, name: str|null, instrument_type: "stock"|"etf", currency,
                      sector: str|null, industry: str|null }],
    "portfolios": [{ "name": str, "benchmark": str|null,       // benchmark by NAME, not id
      "transactions": [{ symbol, side, kind, shares: str, price: str, fees: str,
                         executed_on: ISO, notes: str|null,
                         recurring_key: str|null, scheduled_for: ISO|null }],
      "recurring_transactions": [{ key: str, symbol, side, amount_type, dollar_amount: str|null,
                                   share_amount: str|null, frequency, anchor_on: ISO,
                                   next_run_on: ISO, end_on: ISO|null, active: bool }] }] }
  ```
  **Symbolic on purpose** — no primary keys anywhere, because the feature exists to move data
  between databases whose ids disagree. `recurring_key` is file-local (`"r1"`, `"r2"`) and links a
  materialized transaction to its rule. Excluded deliberately: ids, `series_version`, timestamps,
  `paused_reason`/`consecutive_skips` (materializer runtime state), and all prices/splits/dividends
  (provider-owned and re-fetchable). Export → import → export is a byte-identical fixed point.
- `POST /api/v1/portfolios/import` → **multipart/form-data**, not JSON. Fields: `file` (required),
  `on_conflict` (`"rename"` default | `"skip"`), `dry_run` (`"true"`/`"false"`). Format is sniffed
  from the file's CONTENT, never its name or MIME type — three are accepted:
  the native envelope above, a broker **activity ledger** CSV
  (`"wealthsimple.activities"`, issue #68 — a real trade history), or a broker
  **holdings snapshot** CSV (`"wealthsimple.holdings"` — no trade dates, so trades are
  synthesized). Max 8 MiB.
  ```jsonc
  { "import": { "format": str, "dry_run": bool,
      "totals": { portfolios_created, portfolios_skipped, portfolios_failed,
                  transactions_created, recurring_created,
                  splits_created },                           // all numbers
      "warnings": [str],                                       // file-level, belong to no portfolio
      "portfolios": [{ "name": str,                            // what the FILE asked for
                       "imported_as": str|null,                // what it became; null if skipped/failed
                       "status": "created"|"renamed"|"skipped"|"failed",
                       transactions_created: num, recurring_created: num,
                       "errors": [str], "warnings": [str] }] } }
  ```
  **A partly-failed import is a 200, not an error** — the per-portfolio detail is the payload, and an
  error envelope cannot carry it. 422 on the `file` field is reserved for a file that cannot be READ
  at all (missing/empty/oversized/unrecognized/bad JSON/foreign format string). Atomicity is per
  portfolio: a failed one is rolled back whole, its siblings still commit. Nothing is overwritten.
  Client note: `status` is modelled as `z.string()`, not an enum — schema failures throw in dev, so
  enumerating it would turn a newer backend into a blank dialog. `totals.splits_created` is
  `z.number().default(0)` for the same reason (it postdates the rest of the contract).
  `splits_created` counts `split_events` rows written, which are **instrument-global** — hence on
  `totals` rather than on a portfolio row. It is non-zero only for the activity-ledger format, which
  reports a split as a share delta that the parser converts back to a ratio; an existing event for
  the same (instrument, ex_date) is never overwritten.

## Known envelope inconsistency (deliberate, don't "fix" in zod)
`/candles` is a bare object; `/summary` and `/allocations` are wrapped. Model exactly as-built.
`/portfolios/export` is a **file download** (no envelope at all) and `/portfolios/import` is wrapped
under `import` — both as-built and intentional.
