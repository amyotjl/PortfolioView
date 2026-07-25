# Status (living document)

Last verified: 2026-07-24. M0–M6 all merged and closed. The M4 follow-up defects (#59/#60)
are fixed and merged, so **M4 is now complete with no open defects**. Next up is M7
(transaction/recurring UIs, #49–51, with #63 folded in).

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
| M4 | API | Full REST API, error envelope, CSRF, caching, contract test suite | ✅ closed (#29–39, plus follow-up defects #59/#60 fixed and merged) |
| M5 | Frontend shell + auth + portfolios | Router/Pinia/PrimeVue shell, zod schemas, auth pages, portfolios CRUD, Vitest harness | ✅ closed (#40–44) |
| M6 | Dashboard | Candlestick + cash-flow + drawdown linked chart, stat tiles, allocation donuts | ✅ closed (#45–48) |
| M7 | Transaction/recurring UIs | Transaction form drawer, recurring-transactions page, Playwright e2e smoke | ⬜ not started (#49–51) — **#63** (name enrichment) folded in |
| M8 | Extra visualizations | Contribution-vs-growth stacked area, sector treemap | ⬜ not started (#52–53) — **#64** (portfolio export/import, user-filed) added |
| M9 | Local deploy | Production Dockerfile/compose profile, boot catch-up sync, Sync-now button, persistence check | ⬜ not started (#54–58) |

## Frontend building blocks already in `frontend/src/` (M5+M6 — extend, don't rebuild)
- **Charts** (`charts/`): `echarts.ts` registers ECharts modularly (`use([...])`) — add new chart types (e.g. M8's treemap) to that one call; import `VChart` from here, never from `vue-echarts` directly. `candles.ts`/`donuts.ts` are pure option builders; `theme.ts` maps `--pv-*` tokens into chart colors; `colors.ts` has the validated ordinal-ramp helpers.
- **Composables** (`composables/`): `usePortfolios`, `useBenchmarks`, `usePortfolioCandles` (key `['candles', pid, from, to, benchmark]`), `useSummary` (`['summary', pid]`), `useAllocations` (`['allocations', pid]`). **Any transaction/recurring mutation must invalidate all four data keys plus `portfolios`** — the server bumps `series_version` on mutation.
- **Dashboard components** (`components/dashboard/`): `ChartCard` (chart/table toggle), `StatTile(Row)`, `DashboardEmptyState`, table-twin components — reusable for M8's extra visualizations.
- **Shared UI/lib**: `FormField`/`FormAlert`/`ConfirmDialog`, `mapApiError`, `formatCurrency`/`formatPercent`/`formatDate` (decimal-string-safe), `safeRedirectTarget`, `buildSparkline`, `presetToRange`/`useDashboardParams` (URL-mirrored filter state — copy this pattern for new filters).
- **PrimeVue PT presets** (`primevue/pt.ts`): button/inputText/select/dialog/selectButton/toggleSwitch — add new ones here as new components are used.
- Tooltip/label strings built as innerHTML **must** go through `escapeHtml` (tickers/sector names are untrusted) — verified in place for the dashboard; keep doing it for any new chart.

## Open tracked defects & enhancements (outside the milestone they surfaced in)

| Issue | Milestone | What | Status |
|---|---|---|---|
| [#63](https://github.com/amyotjl/PortfolioView/issues/63) | M7 | `listed_instruments.name` is `null` on 100% of rows — Tiingo's bulk ticker file has no name column (by design in `Directory::ImportJob`); search/autocomplete can only ever match on symbol until enriched | Open, not started. Candidate fix: backfill from `instruments.name` (already fetched via FMP for any symbol the user has touched) without a real-time enrichment call |
| [#64](https://github.com/amyotjl/PortfolioView/issues/64) | M8 | Export/import portfolios: 2 backend endpoints (download a portfolio file; upload + ingest it), 2 frontend buttons (Export / Import with file dialog), tests | Open, not started. User-filed 2026-07-21, outside the original backlog — decompose into backend/frontend/tester slices when picked up |

### Resolved (kept for traceability — don't reintroduce these)
- **#59** (M4) — unmatched `/api/*` non-GET returned 422 HTML instead of the 404 JSON
  envelope. Fixed 2026-07-24 by `skip_forgery_protection` on `ErrorsController` **only**:
  it inherits `ActionController::Base` directly, so it picked up the framework-default
  forgery protection that `ApplicationController` configures separately. That skip is
  load-bearing — removing it reintroduces the 422. Real endpoints are unaffected
  (`CsrfPairContractTest` locks this).
- **#60** (M4) — holdings pre-flight with an `as_of` before the calendar's earliest trading
  day returned the *current* position. Fixed 2026-07-24 by removing the `|| last_day`
  fallback in `HoldingsController#shares_as_of`; `nil` is a genuine zero position and the
  existing guard already renders `"0.0"`. Don't "restore" the fallback — it's the bug.

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
