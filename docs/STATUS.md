# Status (living document)

Last verified: 2026-07-21. M5 fully merged and its milestone closed. M6 dashboard batch and
the M4 follow-up fixes (#59/#60) are both in flight in isolated worktrees.

**Keep this current.** Whoever closes an issue or a milestone updates the tables below in
the same session — this file exists so a future agent doesn't have to re-run `gh issue list`
for a full-repo status check. Still use `gh issue view N` when you need one issue's exact
acceptance-criteria text.

## Milestones

| # | Milestone | Scope | Status |
|---|---|---|---|
| M0 | Environment & project setup | Agent team, GitHub repo/labels/milestones, dev containers, Rails+Vue scaffold | ✅ closed |
| M1 | Auth + schema | Auth generator, invite-gated registration, full schema, benchmark seeds | ✅ closed (#5–10) |
| M2 | Price pipeline | Tiingo/TwelveData/FMP adapters, backfill/sync jobs, directory import, budget breakers | ✅ closed (#11–21) — verified against real Tiingo/FMP keys, including the real AAPL 2020-08-31 4:1 split |
| M3 | Domain services | Holdings calculator, position validator, valuation, benchmark simulation, recurring materializer | ✅ closed (#22–28) |
| M4 | API | Full REST API, error envelope, CSRF, caching, contract test suite | ✅ closed except 2 tracked defects — #29–39 closed; **#59, #60 open**, fix committed on branch `fixes/059-060`, tester verifying |
| M5 | Frontend shell + auth + portfolios | Router/Pinia/PrimeVue shell, zod schemas, auth pages, portfolios CRUD, Vitest harness | ✅ closed (#40–44) |
| M6 | Dashboard | Candlestick + cash-flow + drawdown linked chart, stat tiles, allocation donuts | 🚧 in progress — **#45–48 open**, branch `m6/041-044` in flight |
| M7 | Transaction/recurring UIs | Transaction form drawer, recurring-transactions page, Playwright e2e smoke | ⬜ not started (#49–51) — **#63** (name enrichment) folded in |
| M8 | Extra visualizations | Contribution-vs-growth stacked area, sector treemap | ⬜ not started (#52–53) — **#64** (portfolio export/import, user-filed) added |
| M9 | Local deploy | Production Dockerfile/compose profile, boot catch-up sync, Sync-now button, persistence check | ⬜ not started (#54–58) |

## Open tracked defects & enhancements (outside the milestone they surfaced in)

| Issue | Milestone | What | Status |
|---|---|---|---|
| [#59](https://github.com/amyotjl/PortfolioView/issues/59) | M4 | Unmatched `/api/*` non-GET without a CSRF token returns 422 HTML in dev instead of the 404 JSON envelope (CSRF verification runs before `ErrorsController` renders) | Fix committed on `fixes/059-060` (`skip_forgery_protection` on `ErrorsController` only, real endpoints unaffected — `CsrfPairContractTest` still passes); tester gate running |
| [#60](https://github.com/amyotjl/PortfolioView/issues/60) | M4 | Holdings pre-flight with `as_of` before the calendar's earliest trading day returns the *current* position instead of zero (`\|\| last_day` fallback bug in `HoldingsController#shares_as_of`) | Fix committed on `fixes/059-060` (fallback removed, nil → `"0.0"`); tester gate running |
| [#63](https://github.com/amyotjl/PortfolioView/issues/63) | M7 | `listed_instruments.name` is `null` on 100% of rows — Tiingo's bulk ticker file has no name column (by design in `Directory::ImportJob`); search/autocomplete can only ever match on symbol until enriched | Open, not started. Candidate fix: backfill from `instruments.name` (already fetched via FMP for any symbol the user has touched) without a real-time enrichment call |
| [#64](https://github.com/amyotjl/PortfolioView/issues/64) | M8 | Export/import portfolios: 2 backend endpoints (download a portfolio file; upload + ingest it), 2 frontend buttons (Export / Import with file dialog), tests | Open, not started. User-filed 2026-07-21, outside the original backlog — decompose into backend/frontend/tester slices when picked up |

## GitHub issue numbering
Backlog file number + 4 = issue number (e.g. backlog `034` → `#38`). Issues #1–4 predate
backlog-driven work and aren't separately tracked.

## As-built deviations from docs/PLAN.md
All tester-approved; full detail lives in [docs/API_SHAPES.md](API_SHAPES.md).
- Benchmark fill = close of the first trading day **on or after** the transaction date (PLAN
  wording tightened to match the as-built behavior).
- Flow `kind` in `/candles` is the trade side (`"buy"`/`"sell"`), not a separate flow-type enum.
- `benchmark_clamped` is the OR of the over-withdrawal clamp and the short-history clamp.
- Recurring preview returns `{scheduled_for, execution_on}` objects, not bare date strings.
- Pagination meta shape: `{page, per_page, total_count, total_pages}`.
- `/candles` is a bare top-level object; `/summary` and `/allocations` are wrapped —
  deliberate, see API_SHAPES.md's "Known envelope inconsistency" section.
- `US_EXCHANGES` recognized for transaction validation: NYSE, NASDAQ, AMEX, NYSE ARCA, NYSE
  MKT, BATS, IEX, CBOE.

## Environment facts worth knowing
- Real Tiingo/TwelveData/FMP keys are present in the dev `.env` and have been verified
  against real data: AAPL's actual 2020-08-31 4:1 split, real dividend history, real FMP
  sector/industry metadata. Demo-verification runs clean up their throwaway
  users/portfolios/transactions back to zero but **keep the fetched instrument/price/
  split/dividend/directory data cached** — AAPL, MSFT, SPY, QQQ, VTI don't need re-fetching
  (saves quota).
- DB host port is 5433 (see root [CLAUDE.md](../CLAUDE.md)).
