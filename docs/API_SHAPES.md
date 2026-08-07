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

**Age sits after length deliberately, and it is a trade rather than a free win.** Age before length buries recent listings behind old obscure ones — a 1998 ADR still carrying recent prices outranked the 2023 `ARM`, and ARM/NET/RDDT/SOFI all fell out of the 2-character cap. Age *after* length is a strict refinement of the pre-#71 ordering (it only breaks ties previously broken alphabetically, so no row crosses a length boundary: 0 of 676 two-letter prefixes change their top-20 length profile, against 376 of 676 the other way round).

The cost, measured exhaustively rather than from a sample: **1,617 symbols** drop out of a 2-character top-20 they previously reached, **1,219** of them live/tradeable/non-fund/≤4 chars (952 if you additionally require a major venue; the difference is almost all BATS). Named casualties include SNAP, MTCH, MBLY, ASAN, CELH, VICI and ARCC. What that buys is the head of the distribution — AAPL, MSFT, AMZN, META, TSLA, AVGO, COST become reachable at two characters for the first time. **Every displaced symbol remains reachable at three characters** — verified exhaustively, 1,617/1,617, median rank 3. Residual bias: post-2020 rows hold 34.2% of top-20 slots versus 42.4% with no age tier, while 55.5% of live tradeable non-fund rows are post-2020.

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
    "cash":      [{ "t": ISO, "v": str }] | null,   // #80 — signed, END-OF-DAY; null ⇔ untracked
    "meta": { "partial": bool, "filled_dates": ISO[], "benchmark_clamped": bool, "approximation": str,
              "flow_basis": "cash"|"trades", "cash_negative": bool, "cash_negative_since": ISO|null } }
  ```
  Notes: flow `kind` is the trade side (DRIP is excluded from flows entirely); `benchmark_clamped` is the OR of over-withdrawal and short-history clamps; `net`/`amount` signed (buy +, sell −); `from`/`to` optional (inception → last trading day); malformed date → 422 on that field.
- `GET .../summary` → `{"summary": {current_value: str, net_deposits: str, total_return: str, total_return_pct: str|null, benchmark_return_pct: str|null, vs_benchmark_edge_pct: str|null, max_drawdown_pct: str, as_of: ISO|null, holdings_value: str, cash_balance: str|null, deposit_basis: "cash"|"trades", cash_negative: bool, cash_negative_since: ISO|null}}` (pcts are fractions, 6dp; null when net_deposits ≤ 0 / no benchmark).
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

## Sync status (issue #56) — `GET /api/v1/sync`

The **global** price-cache freshness snapshot the Settings page renders (#57). Session-
authenticated like every other `/api/v1` GET; no CSRF on a GET. Always `200` for a signed-in
caller — an empty cache is a valid answer, not a 404. `401` `unauthenticated` signed out.

```jsonc
{ "sync": { "latest_price_on":    "2026-07-24" | null, // ISO date; MAX(latest_price_on) over referenced instruments
            "last_trading_day":   "2026-07-24" | null, // ISO date; Trading::Calendar.last_day
            "stale":              false,               // bool, never null
            "instruments_behind": 0,                   // integer, never null; 0 when all current
            "pending":            false,               // bool, never null — a sync claim is held right now
            "requested_at":       null } }             // ISO-8601 UTC | null; null iff pending is false
```

Both date fields are `null` together on a **fresh database** (nothing cached yet) and `stale`
is then `true` — #57 must render that case ("never synced"), it is not hypothetical.

**`instruments_behind` is NOT 0 on a fresh database — measured live it is 3.** This file said 0
until #58's runtime verification measured otherwise. `db/seeds.rb` creates the three benchmark
instruments (SPY, VTI, QQQ), and a benchmark counts as *referenced*, so on an untouched deploy
there are three referenced instruments with `latest_price_on = NULL`, each individually behind.
The service is right and the old sentence was wrong: a brand-new instance correctly reports
"3 symbols are behind".

**Why not `/summary`'s `as_of`:** that is portfolio-scoped and is `null` for a portfolio with no
price coverage (an imported CAD portfolio does exactly this), which reads as "never synced" when
the truth is "this portfolio has no prices". Settings is not portfolio-scoped.

**`stale` is `max(latest_price_on)` over referenced instruments vs the *expected session*: the
most recent WEEKDAY in ET, counting today once it is past 22:00 ET.** It is not the literal
`max(latest_price_on) < last_trading_day` that PLAN.md § Deployment words the boot catch-up as.
That comparison is **degenerate and can never be true**: a trading day is *defined* as a date
where SPY has a `daily_prices` row, SPY is a seeded benchmark and therefore always referenced, so
`Calendar.last_day` is derived FROM the same cache the max is taken over — a box asleep for a
week has a week-old cache *and* a week-old calendar, and they agree. Only the wall clock knows.

The **22:00 ET cutoff** is the slot `config/recurring.yml` schedules the nightly sync in and the
hour by which US EOD data has landed, so today's close *is* expected once it passes. (Issue #59:
this replaced an earlier cutoff-free "strictly before today" rule that called the cache fresh for
a full evening every weekday, and disagreed with the boot catch-up's own rule — on a Monday at
23:00 ET the app fetched while this endpoint said `stale: false`. There is now exactly one
predicate, `Prices::Freshness`, and `Boot::CatchUp` consumes it.) **Weekend-aware, deliberately
not holiday-aware** (the app has no holiday table by design): on the ~9 US market holidays a
year, and the evening of each, `stale` reads `true` while the cache is in fact current. Chosen
direction — a false "stale" costs one idempotent no-op sync; a false "fresh" costs the user
trusting old numbers. Don't "fix" it without a holiday source.

**`instruments_behind` is the signal `stale` structurally cannot give.** `stale` is a MAX, and
SPY is always in the set, so **one** referenced instrument whose fetch failed while SPY's
succeeded can never move it. This counts referenced instruments individually behind the expected
session (a `NULL latest_price_on` — never priced — counts as behind). Therefore
`stale: false, instruments_behind: 1` is a real, meaningful state: *the cache as a whole is
current, one symbol is not*. `stale: true` implies `instruments_behind >= 1`; the converse does
not hold. `latest_price_on` deliberately stays the MAX — it is the display value ("prices current
through …"), not a health check.

**`sync` wraps a DIFFERENT key set on GET than on POST** — GET is a state snapshot
(`latest_price_on`/`last_trading_day`/`stale`/`instruments_behind`/`pending`/`requested_at`),
POST is an action result
(`status`/`requested_at`). Two zod schemas, not one. POST's shape was frozen and coded against
before GET existed and was deliberately not reshaped. `requested_at` means the same thing in
both: when the currently-pending sync was claimed.

## Sync triggers (issue #56) — two doors, one body

Both endpoints enqueue the **same** `Prices::DailySyncJob` through the **same**
`Prices::SyncTrigger`, and therefore share one dedupe lease. Identical response body on
purpose, so the SPA never has to care which door it came through:

```jsonc
{ "sync": { "status": "enqueued" | "already_pending",
            "requested_at": "2026-07-26T17:42:02Z" } }   // ISO-8601 UTC, always ...Z
```

- `POST /api/v1/sync` — **the SPA's supported path** (the Settings "Sync now" button, #57).
  Session cookie **+ CSRF pair**, like every other non-GET. Takes no parameters and no body.
  `202` on success; `401` `unauthenticated` signed out; `403` `invalid_csrf_token` without the
  `X-XSRF-TOKEN` header. A bearer token does **not** authorize this route.
- `POST /api/internal/jobs/daily_sync` — **machine callers only** (cron / `curl` from the host).
  `Authorization: Bearer <INTERNAL_API_TOKEN>`; **no session, no CSRF, no browser-UA check**.
  `202` on success; `401` `unauthenticated` (envelope + `WWW-Authenticate: Bearer realm=
  "portfolioview-internal"`) for a missing, malformed or wrong token — **and always when
  `INTERNAL_API_TOKEN` is unset or blank** (fails closed). Note it is under `/api/internal`,
  **not** `/api/v1`, and is deliberately excluded from the contract suite's `/api/v1` auth sweep.

**The browser must never hold the internal token.** Anything the JS bundle can read, every user
and every devtools panel can read; `/api/v1/sync` exists precisely so the UI can trigger a sync
with the credential the browser already has.

**Dedupe: `202` in BOTH outcomes** — the request was accepted either way; `status` says what
happened. The trigger claims a cache lease (`prices/daily_sync/claim`, TTL
`Prices::SyncTrigger::LEASE` = 10 min) with an atomic `unless_exist` write; the winner enqueues,
everyone else gets `already_pending` and enqueues nothing. On `already_pending`, `requested_at`
is the **pending sync's** claim time, not this request's — so a UI can say "a sync requested at
13:42 is already running". Nothing releases the lease early; it just expires, so a dead job can
never wedge the trigger. The nightly `config/recurring.yml` schedule enqueues `DailySyncJob`
directly and bypasses the lease by design.

## Cash transactions (issue #80) — verified live 2026-08-07

`CRUD /api/v1/portfolios/:id/cash_transactions`. Wrapped, like `/transactions`. **There is no
`show` route** (also matching `/transactions`) — `index`, `create`, `update`, `destroy` only.

```jsonc
{ "cash_transaction": { id: num, portfolio_id: num, kind: str, amount: str,
                        occurred_on: ISO, notes: str|null, created_at: ISO, updated_at: ISO } }
{ "cash_transactions": [ ... ], "meta": { page, per_page, total_count, total_pages } }   // newest-first
```

`kind` ∈ `deposit | withdrawal | interest | dividend_cash | tax | fee`. Model as `z.string()`, not
an enum — the same call `import.status` already makes.

**EVERY MONEY FIGURE ON THE WIRE IS SIGNED, in both directions** — `amount` here, `cash_balance`,
`cash[].v`, and the pre-existing `flows[].net`/`amount`. `deposit` is always positive and
`withdrawal` always negative (a DB CHECK plus a model validation, so a wrong sign is a **422 on
`amount`**, not a coerced value). The other four kinds carry the **broker's** sign, because they are
genuinely ±: a dividend reversal is a negative `dividend_cash` and a tax refund a positive `tax`.
An unsigned-magnitude-plus-`kind` contract was designed first and **rejected** for exactly that
reason — it cannot express a refund. The client's *form* is unsigned (the shared `DECIMAL` regex
rejects a sign) and applies the sign at the composable boundary; that is a frontend concern only.

`create`/`update` additionally carry
`"meta": { cash_balance: str, cash_negative: bool, cash_negative_since: ISO|null }` so a toast can
report the balance without waiting for a refetch. It is computed from the same ledger `/summary`
uses, and a test pins that the two agree. **The entry is NEVER rejected for driving cash negative** —
verified live: a $62,486.95 buy against a $21,495.05 balance returns **201**, and a further
withdrawal on top of the resulting negative balance also returns 201. `DELETE` → 204, no body.

Money strings follow the house `BigDecimal#to_s("F")` convention and therefore **drop trailing
zeros** — `"-400.0"`, `"0.0"`, `"25000.0"`, not `"-400.00"`. Do not special-case cash to 2dp: the
contract test suite already compares money strings across endpoints, and a 2dp field inside an
otherwise-1dp object would break that class of check.

### `cash_balance` is `str|null` and `null` is NOT zero

`null` means **"this portfolio does not track cash"**; `"0.0"` means **"it tracks cash and is
exactly flat"**. Both states are reachable and they mean different things. A single `?? 0` or
`|| 0` anywhere in the chain turns every pre-#80 portfolio's dashboard into a lie, because the
full-cash-account formula applied to a portfolio with no cash rows yields `−Σ buy costs`.

`deposit_basis` / `meta.flow_basis` are modelled client-side as `z.enum(['cash','trades'])` — a
deliberate departure from the `z.string()` rule used for `kind` and `import.status`, on the grounds
that a third basis is unrenderable anyway and mislabelling the *denominator of every return
percentage* is worse than failing loudly. So the server must emit exactly one of those two strings,
never null, never absent.

### Invariants a client may rely on (each has a contract test)

- `current_value == holdings_value + cash_balance` when tracked; `== holdings_value` when not.
  Verified live: `24514.2 == 65606.1 + (−41091.9)`.
- `summary.deposit_basis == "cash"` ⇔ `candles.cash != null` ⇔ `summary.cash_balance != null`.
- **`Σ flows[].net` over all time == `summary.net_deposits`, in both bases.**
- `cash[]`'s last point == `summary.cash_balance`.
- The basis is **window-independent**: a future-dated deposit cannot make one endpoint report
  `"trades"` while another reports `"cash"`.

### `flows` is EXCLUSIVE, and this is the part most likely to be "fixed" wrongly

On the **cash** basis `flows` carries **only** deposits and withdrawals — **trades are absent**,
`items[].ticker` is `null`, and `items[].kind` is the cash kind. Under a full cash account a trade
is an internal transfer that does not move total value, so a trade bar in the "flows explain value
jumps" pane would actively mislead. On the **trade** basis it is byte-identical to M4.

Consequences: `items[].ticker` is now `str|null` and `items[].kind` is **no longer a `buy|sell`
enum** — model both permissively. And if trade bars are ever wanted back they must go in a
**separate `trade_flows` key**, never mixed into `flows`, because `Summary` sums `flows[].net` and a
mixed array would silently corrupt `net_deposits`.

### Deliberate divergence: `/allocations` vs `/summary`

`/allocations`' `total_value` is **holdings only**, so for a cash-tracked portfolio it is **less
than** `/summary`'s `current_value` by the cash balance. Not a bug. A "Cash" slice would change
`total_value`, every `weight`, the `by_sector` label set, and would break the pinned invariant that
`by_instrument[].sector` is byte-identical to its `by_sector` label — the join key the sector
treemap's hierarchy depends on.

### Caching

`Candles::Cache::VERSION` moved **`v1` → `v2`** for this feature, and the bump is a requirement
rather than insurance: `series_version` alone does not cover it, because an untracked portfolio's
payload never changes and so its key never rotates, leaving warm `v1` entries that lack the new
`meta` keys. A cash mutation bumps `series_version`.

## Known envelope inconsistency (deliberate, don't "fix" in zod)
`/candles` is a bare object; `/summary` and `/allocations` are wrapped. Model exactly as-built.
`/portfolios/export` is a **file download** (no envelope at all) and `/portfolios/import` is wrapped
under `import` — both as-built and intentional.
