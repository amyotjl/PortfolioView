# PortfolioView — Implementation Plan

## Context

Greenfield project in `a:\PorfolioView` (currently empty). The goal is a deployed web app to track personal stock portfolios and visualize them: a candlestick chart of total portfolio value, pie charts of stock/sector distribution, a cash-flow-matched index benchmark, and recurring transactions that materialize automatically.

**Decisions made with the user:**
- Backend **Ruby on Rails 8.x**, frontend **Vue 3** — user's choice
- **Runs locally for now** (Docker Compose on the user's machine); architecture stays deployable to a host later. **Single-user / invite-only** registration
- **Daily EOD** price data is sufficient
- Benchmark = **cash-flow-matched**: simulate the user's exact deposits, on the same dates, into an index ETF (e.g. SPY)
- Dev environment: **Docker / Dev Containers** on Windows 11

The design below was produced by parallel research/design agents and hardened by an adversarial review that traced the split math, benchmark math, and API contracts; its fixes are baked in throughout (marked where non-obvious).

## Stack (locked)

| Layer | Choice | Why |
|---|---|---|
| Backend | Rails 8.x, **not** `--api` mode | Cookie/session middleware + CSRF needed for same-origin SPA auth |
| Jobs/Cache | Solid Queue + Solid Cache (Postgres-backed) | Rails 8 defaults, no Redis |
| Database | PostgreSQL 16 | |
| Auth | Rails 8 built-in auth generator + small invite-gated `RegistrationsController` | ~200 lines of editable code; Devise adds no value for a JSON SPA |
| Frontend | Vue 3.5 + Vite + TypeScript + Pinia + Pinia Colada (server-state cache) + Vue Router | |
| UI kit | PrimeVue 4 (unstyled mode) + Tailwind CSS 4 | DataTable/AutoComplete/DatePicker for free; dense non-Material look |
| Charts | **Apache ECharts** (`vue-echarts`), exclusively | One Apache-2.0 library covers candlestick + linked panes + pie + treemap + calendar heatmap + correlation matrix. (Lightweight Charts can't do pies; Highcharts is paid; Chart.js financial plugin is not production-grade) |
| Forms | vee-validate + zod (schemas shared with API response parsing) | |
| HTTP (Ruby) | Faraday + faraday-retry; hand-rolled ~50-line provider adapters | No maintained Tiingo gem exists; stale community gems are riskier than plain HTTP |

## Free data sources (live-verified July 2026)

- **Tiingo (primary, prices)** — free tier: 1,000 req/day, 50/hr, **500 unique symbols/month**, 30+ years of daily history. Its EOD endpoint returns **raw OHLCV + `splitFactor` + `divCash` per row** — exactly what the split-correct design needs. One call backfills a ticker's full history (must pass explicit `startDate=1900-01-01`). Personal-use license — fine for single-user; commercial tier is $50/mo if that ever changes.
- **FMP (sector/industry metadata)** — free 250 req/day; `/stable/profile` gives sector + industry; one-time lookup per ticker, cached forever in Postgres.
- **Twelve Data (fallback, prices)** — free 800 credits/day. Its free series are split-adjusted and it exposes no free split events, so the fallback adapter is **forward-delta-only with `adjust=none`** — it must never backfill or ingest splits (a fallback backfill would silently mix adjusted/raw bases and corrupt valuations 4× across a 4:1 split).
- **Tiingo `supported_tickers.csv`** (free bulk file) — imported weekly into a local symbol directory table so ticker autocomplete never burns the 500-symbols/month quota.
- Rejected: Alpha Vantage (25 req/day), Finnhub (historical candles now premium-only), EODHD free (20/day, 1-yr depth), Marketstack (100 req/month), Stooq (now serves a proof-of-work anti-bot challenge to scripts), Yahoo unofficial API (ToS risk + blocks cloud IPs — dev-only emergency), Polygon/Massive (free tier unconfirmed post-rebrand).
- ETFs (SPY, VOO) have no sector on free tiers → bucketed as **"ETF / Fund"** in the sector pie.

## Deployment: local via Docker Compose (for now)

The app runs on the user's machine with `docker compose up`: one `web` container (Rails, production or dev mode, Solid Queue embedded in Puma via `SOLID_QUEUE_IN_PUMA=true`) + one `db` container (Postgres 16 with a named volume). Free, always available at `http://localhost:3000`, no accounts needed.

**Local-machine reality — the box won't reliably be awake at 21:30 ET**, so scheduled jobs alone can't be trusted:
- **Catch-up on boot**: an initializer enqueues `Prices::DailySyncJob` on app start when `max(latest_price_on)` is behind the last trading day; the sync already fetches only the delta since the last cached date, so this is cheap and idempotent. The recurring-transaction materializer already loops through all missed slots, so it catches up the same way.
- **Manual "Sync now" button** in Settings, backed by the token-guarded `POST /api/internal/jobs/daily_sync` endpoint — which doubles as an external-cron hook if the app is ever moved to a host later.
- The Solid Queue recurring schedule still runs nightly for whenever the machine happens to be on.

Nothing in the architecture is local-only (same-origin cookies, Postgres, containerized build), so a later move to hosted (Render/Fly/Kamal-on-VPS) is a deploy change, not a redesign.

Development mirrors production's multi-database layout: Solid Queue and Solid Cache run against dedicated `app_development_queue` / `app_development_cache` databases in the same Postgres instance (created by `db:prepare` on boot) — do not "simplify" them back onto the primary DB. The compose web command clears a stale `tmp/pids/server.pid` before boot (a leftover pidfile from an unclean shutdown otherwise aborts Rails with "A server is already running"); carry this into the M9 production compose profile.

## Architecture

```
Vue 3 SPA (Vite build, served by Rails) ──same-origin──▶ Rails 8 JSON API (/api/v1)
                                                           ├─ PostgreSQL (app data + cached OHLC + Solid Queue/Cache)
                                                           ├─ Solid Queue (in-Puma): daily sync, backfill, recurring materializer
                                                           └─ PriceProvider adapters: Tiingo (primary) / TwelveData (delta-only) / FMP (metadata)
```

Same-origin everywhere: dev uses Vite proxy `/api → :3000`, prod serves the Vite build from Rails `public/` with an SPA catch-all route. **No CORS, no JWT** — HttpOnly session cookie + CSRF token (`XSRF-TOKEN` cookie ↔ `X-XSRF-TOKEN` header, one pair used consistently by both sides).

## Database schema

All money/shares are `numeric`, never float: shares `numeric(20,8)`, prices `numeric(16,6)`.

- `users`, `sessions` — Rails 8 auth generator (citext email, bcrypt, DB-backed revocable sessions)
- `portfolios` — user_id, name (unique per user), benchmark_id, `series_version` int (cache-buster)
- `benchmarks` — curated seeded list (SPY, VTI, QQQ…) → instrument_id
- `instruments` — symbol (unique expression index on `upper(symbol)`), name, sector, industry, instrument_type (stock/etf), currency, `prices_backfilled_at`, `earliest_price_on` / `latest_price_on`
- `listed_instruments` — local symbol directory from Tiingo's bulk CSV (symbol, name, exchange, asset_type, currency), refreshed weekly; backs autocomplete + validation
- `daily_prices` — instrument_id, date, **raw unadjusted** OHLC, volume, source; **UNIQUE (instrument_id, date)**; CHECK `high >= low AND low > 0` (bad provider rows are validated and skipped *before* the batch `upsert_all` so one bad row can't fail the batch)
- `split_events` — instrument_id, ex_date, **`ratio numeric(12,6)`** (stores Tiingo's decimal splitFactor directly; no integer-rationalizing of 10:9 oddities); UNIQUE (instrument_id, ex_date)
- `dividend_events` — instrument_id, ex_date, cash_per_share; **captured from Tiingo's `divCash` from day one** (cheap to capture, expensive to backfill later; powers the future dividend-timeline chart and total-return benchmark)
- `transactions` — portfolio_id, instrument_id, side (buy/sell), **kind (normal / dividend_reinvestment)**, shares (>0), price, **fees numeric(12,2) default 0**, executed_on, notes, recurring_transaction_id + scheduled_for with **partial UNIQUE index** (materialization idempotency)
- `recurring_transactions` — portfolio_id, instrument_id, side (**buy only in v1**, validated), amount_type (dollars/shares), dollar_amount / share_amount, frequency (weekly/biweekly/monthly/quarterly), anchor_on, next_run_on (**clamped ≥ creation date** — no surprise historical materialization), end_on, active, paused_reason, consecutive_skips

## Core domain logic (`app/services/`)

**Split model — the correctness crux.** Transactions are stored exactly as executed (trade-date share basis); prices stored unadjusted; splits stored as events; share counts rolled *forward* at read time:

```
CSF(i, t, D) = ∏ ratio of splits with  t < ex_date ≤ D      (cumulative split factor)
shares(i, D) = Σ  sign(side) × tx.shares × CSF(i, tx.executed_on, D)
value(i, D)  = shares(i, D) × unadjusted_close(i, D)
```

Verified example: buy 10 AAPL @ $400 pre-4:1-split → CSF 4 → 40 shares × $134 post-split close ≈ $5,360 ✓. Rule baked in: a split applies at the **start** of its ex-date, before same-day transactions (unit tests for buy-on-ex-date and sell-on-ex-date).

- `Holdings::Calculator` — one sweep over transactions + splits + trading days → `{date => {instrument_id => shares}}`; 3 queries total, no N+1.
- `Positions::Validator` — runs on **every transaction create/update/destroy**: replays the split-adjusted running position from first transaction to today and rejects (422, naming the first offending date) any mutation that drives it negative — catches oversells *and* backdated edits/deletes. No short positions in v1.
- `Portfolios::Valuation` — portfolio OHLC per trading day = Σ shares × component O/H/L/C. Portfolio H/L are documented **bounds** (component extremes don't co-occur; correct for EOD data, flagged in `meta.approximation` and a tooltip disclaimer). Missing instrument-day → forward-fill last close, flagged in `meta.filled_dates`.
- `Benchmarks::Simulation` — each real transaction becomes a synthetic same-dollar trade (dollars include fees on buys, net of fees on sells) of the benchmark ETF at the next trading day's close; fed through the same Calculator/Valuation machinery (SPY splits handled identically). `kind: dividend_reinvestment` transactions are **excluded** from external flows and from benchmark matching (otherwise the shadow portfolio gets free money the benchmark side never models). Over-withdrawal clamps + `meta.benchmark_clamped`; benchmark history shorter than the portfolio clamps the sim start + meta flag. v1 is explicitly labeled **price-return**; v1.1 upgrades to total-return by reinvesting `dividend_events` in the shadow position.
- Drawdown computed server-side from **inception-to-date** closes (all-time peak, not window peak).
- Cost basis: **average cost** in v1 (stated in the UI); per-share basis divides by CSF.

**Trading calendar & time.** A trading day = a date where SPY has a price row (the price cache *is* the calendar — no holiday tables). All "what day is it" logic runs in **America/New_York**. Jobs are scheduled **daily, 7 days a week** (idempotent no-ops on non-trading days) — this dodges the cron-in-UTC bug where `1-5` weekday masks silently skip Friday's 21:30 ET run.

## Price pipeline (`app/jobs/`)

- `Prices::DailySyncJob` → fan-out `FetchInstrumentJob` per active instrument. Fetches from `latest_price_on` **inclusive** — the one-day overlap row is compared against the stored row each night; >20% mismatch flags basis drift (provider silently switching to adjusted data) instead of corrupting the store. Upserts prices + split events + dividend events; serialized via `limits_concurrency`, paced under Tiingo's 50/hr; per-provider daily budget + unique-symbol counters in Solid Cache act as circuit breakers.
- `Prices::BackfillInstrumentJob` — on first reference to a symbol: full history + splits + dividends in one call; on completion **bumps `series_version` of affected portfolios** (so charts rendered against partial data don't cache stale).
- `Instruments::MetadataJob` — FMP profile (sector/industry) once per new instrument; monthly refresh.
- `Directory::ImportJob` — weekly import of Tiingo's supported-tickers CSV into `listed_instruments`.
- Failover: TwelveData adapter for **forward deltas only**; backfills alert instead of failing over.

## Recurring materializer

Nightly `Recurring::MaterializeDueJob`, per active rule: **loop `while next_run_on <= today`** (full catch-up after downtime in one run, each slot filled at its own historical execution-date close); execution date = first trading day ≥ slot; fill price = that day's official close (`shares = dollar_amount / close` rounded 8 dp); insert guarded by the partial unique index (double-run safe); advance from the **anchor** (Jan-31 monthly → Feb-28 → Mar-31, no drift); after N consecutive missing-price skips the rule is **paused with a reason** and surfaced in the UI (no silent forever-skip). Deactivate past `end_on`. Bump `series_version`.

## API contract (frozen — single source of truth, mirrored in zod schemas)

One error envelope everywhere: `{ "error": { "code", "message", "details" } }`; 422 details map onto form fields.

```
GET    /api/v1/session                      # bootstrap: current user + CSRF cookie (the SPA boots from this)
POST   /api/v1/session · DELETE             # login/logout (rate-limited)
POST   /api/v1/registration                 # requires INVITE_CODE env match
GET    /api/v1/instruments/search?q=        # local listed_instruments directory (no API quota burned)
GET    /api/v1/instruments/:id/price?date=  # close prefill for the transaction form
GET    /api/v1/benchmarks
POST/GET/PATCH/DELETE /api/v1/portfolios(/:id)
GET    /api/v1/portfolios/:id/candles?from&to&benchmark=true
GET    /api/v1/portfolios/:id/summary       # lifetime stat tiles (total invested, max drawdown, edge…)
GET    /api/v1/portfolios/:id/allocations   # by_instrument + by_sector pies
GET    /api/v1/portfolios/:id/holdings?instrument_id&as_of   # sell-form pre-flight
CRUD   /api/v1/portfolios/:id/transactions              # POST by symbol (validated vs directory, USD/US-exchange only in v1)
CRUD   /api/v1/portfolios/:id/recurring_transactions
POST   /api/v1/portfolios/:id/recurring_transactions/preview   # dry-run next 3 run dates
POST   /api/internal/jobs/daily_sync        # bearer-token; "Sync now" button + future external-cron hook
```

`/candles` response: portfolio `candles: [{t,o,h,l,c}]`; **benchmark as a close-value line** `{symbol, values: [{t,v}]}` (candle-vs-candle would falsely make the portfolio look more volatile, since portfolio H/L are bounds but a single ETF's are real); `flows: [{t, net, items: [{ticker, kind, amount}]}]` (feeds the cash-flow pane + tooltips); server-computed `drawdown`; `meta: {partial, filled_dates, benchmark_clamped, approximation}`. Stat tiles come from `/summary`, never from a windowed candles payload.

**Caching (Solid Cache):** key = `candles/v1/{pid}/{series_version}/{prices_version}/{from}/{to}/{benchmark_id}` where `prices_version` = max `latest_price_on` across the portfolio's instruments (not just the benchmark's — otherwise a late-landing ticker fetch leaves a stale cached day). Closed-month chunks include `prices_version` and are never cached while `meta.partial`. `series_version` bumps on any transaction/recurring mutation, backfill completion, or late-discovered historical split.

## Frontend (`frontend/` inside the repo)

Pages: `/portfolios` (cards + sparklines), `/portfolios/:id` (**the dashboard**), `/portfolios/:id/transactions`, `/portfolios/:id/recurring`, `/settings` (no currency selector in v1 — backend is USD-only). Router guard boots from `GET /session`.

- **Dashboard**: one ECharts instance, three linked grids — candlesticks + benchmark line (top ~58%), daily net-cash-flow bars (the "volume" pane — a portfolio has no volume; flows explain value jumps), drawdown area — one crosshair, shared dataZoom. Stat-tile row above (from `/summary`). Donuts for stock + sector allocation. Date-range presets (1M…All) mirrored to the URL.
- **Transaction form** (drawer): ticker AutoComplete against the local directory (`forceSelection`), price prefilled from cached close, sell pre-flight warning via `/holdings` (server still authoritative), optimistic insert + undo toast. Weekend-dated transactions allowed — UI copy states they take effect the **next trading day**.
- **Recurring form**: $-amount or share modes, frequency + anchor, `NextRunPreview` showing the next 3 server-computed run dates; paused rules surface their reason.
- Server state lives **only** in Pinia Colada query caches (no hand-rolled chartData store); Pinia stores keep genuinely client-owned state (auth, active portfolio, theme, range preset). Chart options built by pure, unit-testable functions.
- **Launch visualizations**: candlestick+panes, two donuts, contribution-vs-growth stacked area, sector treemap. Backlog (each an independent component + endpoint): calendar returns heatmap, monthly portfolio-vs-benchmark bars, holdings stacked area, correlation matrix, dividend income timeline, TWR/MWR card.

## Repo layout & key files

```
a:\PorfolioView\
├─ .claude/agents/{project-manager,backend-expert,database-expert,ui-expert,tester}.md
├─ .claude/skills/                          # vetted skills installed from online sources
├─ .devcontainer/ + docker-compose.yml     # Ruby 3.4 + Node 22 + Postgres 16 (dev AND local deploy)
├─ Dockerfile                              # multi-stage: vite build → rails + thruster
├─ app/services/{holdings,portfolios,benchmarks,positions}/…
├─ app/jobs/{prices,recurring,instruments,directory}/…
├─ app/lib/price_provider/{base,tiingo,twelve_data,fmp}.rb
├─ app/controllers/api/v1/…  ·  app/controllers/spa_controller.rb
├─ config/recurring.yml                    # Solid Queue schedule (daily ×7, America/New_York pinned)
└─ frontend/                               # Vite + Vue 3 SPA (structure per design)
```

## Agent team, GitHub project & task workflow

**Five specialist agents** defined in `.claude/agents/*.md` (frontmatter: name, description, tools, skills to load), each owning a domain:

| Agent | Domain & scope | Key skills to wire in |
|---|---|---|
| `project-manager` | Decomposes milestones into GitHub issues with acceptance criteria, labels/assigns them, tracks status, reviews completed work against criteria. No code edits — read tools + `gh` only | task decomposition / gh CLI usage; online: PM/planning skills |
| `backend-expert` | Rails 8: models, services (valuation/benchmark/validator), Solid Queue jobs, API controllers, auth. Owns `app/`, `config/`, `lib/` | online: Rails/Ruby best-practice skills |
| `database-expert` | Postgres: migrations, indexes, constraints, `upsert_all` batching, query plans, Solid Queue/Cache tuning. Owns `db/` | online: Postgres/schema-design skills |
| `ui-expert` | Vue 3 + TS + Pinia + PrimeVue + Tailwind + ECharts. Owns `frontend/` | local `frontend-design` + `dataviz` skills (already installed); online: Vue 3 skills |
| `tester` | RSpec (money-math fixtures), Vitest (option builders, formatters), Playwright e2e, verifies each issue's acceptance criteria before it closes | local `verify` skill; online: webapp-testing skills |

**GitHub project setup** (part of M0):
1. Install the GitHub CLI (`winget install GitHub.cli`) and one-time `gh auth login` (interactive browser step — you'll approve it).
2. `git init` + initial commit, then `gh repo create PortfolioView --private --source . --push`.
3. Create GitHub **milestones M0–M9** (mirroring the plan) and **labels** `agent:project-manager`, `agent:backend-expert`, `agent:database-expert`, `agent:ui-expert`, `agent:tester` (issues can't be assigned to non-GitHub users, so agent labels are the assignment mechanism).
4. The project-manager agent converts every milestone below into GitHub issues — each with a description, acceptance criteria, milestone, and exactly one `agent:*` label.

**Execution loop per task**: PM picks the next unblocked issue → the labeled specialist implements it on a feature branch (worktree isolation when tasks run in parallel) → tester verifies the acceptance criteria → commit/PR references `Closes #N` → PM confirms and moves on. Cross-domain tasks (e.g. the `/candles` endpoint) get one issue per domain slice linked together.

**Skill discovery (M0, online)**: search GitHub for current community Claude Code skills per domain — starting points: the official `anthropics/skills` collection and curated `awesome-claude-skills` lists — for Rails, Postgres, Vue 3, and web-app-testing skills. Each candidate is **read and reviewed before installing** (only reputable sources; skills execute with real permissions) into `.claude/skills/`, then referenced from the matching agent definition. Locally available `frontend-design`, `dataviz`, and `verify` skills are wired to the UI and tester agents immediately.

## Implementation milestones

1. **M0 — Environment & project**: agent definitions in `.claude/agents/` + online skill discovery/install; gh CLI install + auth; git init, GitHub repo, milestones, labels; PM agent generates all issues. Then dev container + docker-compose; `rails new . --database=postgresql --skip-jbuilder --skip-hotwire --skip-asset-pipeline`; scaffold `frontend/` with Vite; `bin/dev` runs both.
2. **M1 — Auth + schema**: auth generator, invite-gated registration, all migrations, benchmark seeds.
3. **M2 — Price pipeline**: adapters, backfill, daily sync w/ overlap check, directory import, budget breakers. Verify against a real free Tiingo key. Replace the generator-stub `config/recurring.yml` with the real schedule (daily ×7, America/New_York-pinned), keeping the generated hourly `clear_solid_queue_finished_jobs` cleanup task.
4. **M3 — Domain services + validator** with the unit-test fixtures listed under Verification.
5. **M4 — API**: controllers, serializers, caching, error envelope, request specs.
6. **M5 — Frontend shell**: auth pages, routing, portfolio CRUD, layout/theme.
7. **M6 — Dashboard**: candlestick + panes + tiles + donuts.
8. **M7 — Transactions & recurring UI** incl. preview.
9. **M8 — Extra visualizations** (contribution-vs-growth, treemap).
10. **M9 — Local deploy**: production-mode Dockerfile + compose profile, boot catch-up sync, "Sync now" button, data-volume persistence check across container restarts.

## Verification

- **Unit (the money math)**: AAPL 4:1 split fixture — pre-split buy values correctly post-split; sell-on-ex-date and buy-on-ex-date ordering; oversell + backdated-edit rejection; end-of-month recurrence clamping (Jan-31 → Feb-28 → Mar-31); benchmark exact-dollar matching incl. fees; DRIP exclusion from flows; drawdown from all-time peak.
- **Integration**: seed a demo portfolio (AAPL/MSFT/VOO transactions spanning 2020–2026, crossing the real AAPL split), backfill with a real Tiingo key, spot-check `/candles` values by hand.
- **E2E (Playwright)**: register with invite code → create portfolio → add transaction → candlestick renders → toggle benchmark → pies render.
- **Runtime**: `docker compose up` + `bin/dev`; hit the internal sync trigger; confirm quota counters and idempotent re-runs.

## Prerequisites you'll need (all free)

- API keys: **Tiingo** (api.tiingo.com), **FMP**; optional Twelve Data — stored in Rails credentials/env.
- Docker Desktop (WSL2 backend).
- GitHub account; a one-time interactive `gh auth login` when M0 reaches repo creation (git 2.45 is already installed; `gh` CLI will be installed via winget).

## Deferred to v1.1+ (explicitly out of scope now)

Total-return benchmark (dividend reinvestment — data already captured), non-USD instruments, cash-balance modeling, recurring sells, ticker-rename/merger remediation (documented as a manual admin re-map), dividend timeline / correlation / TWR-MWR charts.
