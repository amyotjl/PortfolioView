# Status (living document)

Last verified: 2026-07-25. **M0–M7 all merged and closed** (M4's follow-up defects #59/#60
fixed along the way). **M8's two visualizations (#52, #53) are implemented and committed on
`m8/052-visualizations`, awaiting the tester gate** — not yet merged, so the issues are
still open. M8's remaining work is #63, #64, #65.

M7 also has an **e2e suite now** (`e2e/`, Playwright) — one command,
`docker compose --profile e2e run --rm e2e`, against the running dev stack. It has
already earned its keep: it caught that **every chart had been rendering at zero
height** since M6 and that **`/register` was unreachable by URL**. Run it after any
change to the dashboard, the shell, or auth routing — those two classes of bug are
invisible to Vitest and to the Rails suite.

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
| M7 | Transaction/recurring UIs | Transaction form drawer, recurring-transactions page, Playwright e2e smoke | ✅ closed (#49–51) — **#63** deferred (still open, see below) |
| M8 | Extra visualizations | Contribution-vs-growth stacked area, sector treemap | 🟡 in progress — #52/#53 built on `m8/052-visualizations` (all four gates green), **awaiting tester sign-off before merge**; #63, #64, #65 still open |
| M9 | Local deploy | Production Dockerfile/compose profile, boot catch-up sync, Sync-now button, persistence check | ⬜ not started (#54–58) |

## Frontend building blocks already in `frontend/src/` (M5+M6 — extend, don't rebuild)
- **Charts** (`charts/`): `echarts.ts` registers ECharts modularly (`use([...])`) — add new chart types (e.g. M8's treemap) to that one call; import `VChart` from here, never from `vue-echarts` directly. `candles.ts`/`donuts.ts` are pure option builders; `theme.ts` maps `--pv-*` tokens into chart colors; `colors.ts` has the validated ordinal-ramp helpers.
- **Composables** (`composables/`): `usePortfolios`, `useBenchmarks`, `usePortfolioCandles` (key `['candles', pid, from, to, benchmark]`), `useSummary` (`['summary', pid]`), `useAllocations` (`['allocations', pid]`). **Any transaction/recurring mutation must invalidate all four data keys plus `portfolios`** — the server bumps `series_version` on mutation.
- **Dashboard components** (`components/dashboard/`): `ChartCard` (chart/table toggle), `StatTile(Row)`, `DashboardEmptyState`, table-twin components — reusable for M8's extra visualizations.
- **Shared UI/lib**: `FormField`/`FormAlert`/`ConfirmDialog`, `mapApiError`, `formatCurrency`/`formatPercent`/`formatDate` (decimal-string-safe), `safeRedirectTarget`, `buildSparkline`, `presetToRange`/`useDashboardParams` (URL-mirrored filter state — copy this pattern for new filters).
- **PrimeVue PT presets** (`primevue/pt.ts`): button/inputText/select/dialog/selectButton/toggleSwitch — add new ones here as new components are used.
- Tooltip/label strings built as innerHTML **must** go through `escapeHtml` (tickers/sector names are untrusted) — verified in place for the dashboard; keep doing it for any new chart.

## Frontend building blocks added in M7 (extend, don't rebuild)
- **`lib/decimal.ts`** — exact comparison of the API's decimal *strings*
  (`compareDecimal`/`decimalGreaterThan`/`isDecimalZero`). Use it any time two money or
  share values are compared; `parseFloat` reintroduces the error the string contract
  exists to prevent. Also holds `sellPreflightMessage`.
- **`lib/tradingDays.ts`** — ET-calendar date helpers (`isWeekend`, `marketClosedNotice`,
  `todayIso`, and the `Date`↔ISO bridges PrimeVue's DatePicker needs). Holidays are
  deliberately **not** modelled client-side; `Trading::Calendar` owns that.
- **`lib/instrumentIds.ts`** — symbol → `instrument_id` derived from a portfolio's own
  transactions + allocations. Needed because `/instruments/search` returns no id and
  **cannot**: `listed_instruments` and `instruments` are separate tables with
  independent primary keys, so a directory row's id would address a *different*
  instrument. Don't "fix" this by adding an id to the search serializer.
- **`forms/transaction.ts` / `forms/recurring.ts`** — decimal fields validated as strings
  by shape/scale/sign, mirroring the `numeric()` columns. Copy this shape for new
  money forms rather than using a numeric input.
- **Composables**: `useTransactions` (list + CRUD, and the one place that invalidates
  *all* series keys), `useRecurringTransactions` (CRUD + the imperative
  `useRecurringPreview`), `useInstrumentForm` (abortable search / price / holdings
  lookups).
- **Components**: `transactions/TransactionsTable`, `transactions/TransactionFormDrawer`,
  `recurring/RecurringRuleCard`, `recurring/RecurringFormDrawer`, `recurring/NextRunPreview`.
- **PT presets** added to `primevue/pt.ts`: dataTable, paginator, autoComplete, datePicker,
  drawer, toast, textarea, tag.

## Frontend building blocks added in M8 (extend, don't rebuild)
- **`lib/money.ts`** — exact integer-cent arithmetic (`toCents`,
  `centsToDecimalString`, `centsToDollars`). Use it whenever a money figure is
  *derived* rather than passed through: `lib/decimal.ts` deliberately only
  *compares*. Money is 2dp by contract, so cents are lossless.
- **`charts/contributions.ts`** — the contribution/growth derivation and its
  stacked-area option. **`charts/treemap.ts`** — the sector hierarchy builder and
  treemap option. Both pure, both spec'd.
- **`charts/colors.ts`** gained `relativeLuminance` / `contrastRatio` /
  `readableInk` — use `readableInk` for any label drawn *inside* a colored fill.
- **`charts/theme.ts`** gained the `capital` identity token. `up`/`down` remain
  reserved for data polarity.
- **`lib/format.ts`** gained `formatCompactCurrency` (moved out of `candles.ts`) —
  the shared value-axis formatter.
- Components: `dashboard/ContributionGrowthChart` + `ContributionGrowthTable`,
  `dashboard/SectorTreemap` + `SectorTreemapTable`.

## Three traps that have already cost a debugging cycle each — read before touching charts or the shell
- **ECharts height must go on a WRAPPER, never on `<VChart>`.** vue-echarts injects an
  *unlayered* `x-vue-echarts { height: 100% }` rule into `<head>`, and unlayered CSS
  outranks Tailwind's `@layer utilities` — so `class="h-[560px]"` on the component is
  silently overridden and the chart collapses to 0px with no error anywhere. This is why
  no chart rendered from M6 until it was caught in M7.
- **Nothing may fetch authenticated-only data before the router guard resolves.**
  `App.vue` waits for a named route, and `usePortfoliosQuery` is `enabled` only when
  authenticated. Without both, a signed-out load of `/register` fires `/portfolios`, and
  the 401 handler redirects to `/login` — making the register page unreachable by URL.
- **A candle's `o` is NOT "the value before that day's trades."** `Portfolios::Valuation`
  values each day's **end-of-day** share count at that day's *opening* price
  (`open += shares * po`, `shares = holdings[date]`, i.e. after the date's transactions).
  So the first candle's open already contains every trade dated on or before it, and
  anything that adds day-one flows to it double-counts them. This shipped a phantom
  "below contributions" band in #52 and a unit fixture *confirmed* the bug, because the
  fixture encoded the wrong reading of `o`. If a derivation combines `o` with `flows`,
  re-read this.

**A related process note, earned twice in M8:** both #52 and #53 passed their unit specs,
type-check and e2e while still visibly wrong on screen (a double-counted band; ECharts'
default palette in the legend; an invisible sector header; the series name drawn as a
header band). **Render a new chart and look at it before calling it done** — a throwaway
Playwright spec that screenshots the card in both themes takes minutes and caught four
defects no assertion did.

## Open tracked defects & enhancements (outside the milestone they surfaced in)

| Issue | Milestone | What | Status |
|---|---|---|---|
| [#63](https://github.com/amyotjl/PortfolioView/issues/63) | M7 | `listed_instruments.name` is `null` on 100% of rows — Tiingo's bulk ticker file has no name column (by design in `Directory::ImportJob`); search/autocomplete can only ever match on symbol until enriched | Open, deliberately deferred out of M7 (the autocomplete ships symbol-only and already handles the null). Candidate fix: backfill from `instruments.name` (already fetched via FMP for any symbol the user has touched) without a real-time enrichment call. **Also worth fixing the relevance ordering while there:** results cap at 20 and prefix matches are alphabetical, so searching `MSF` returns `MSF, MSFAX, MSFBX … MSFN` and **MSFT never makes the list** — verified live |
| [#65](https://github.com/amyotjl/PortfolioView/issues/65) | M7 | a11y: PrimeVue's unstyled `Select` renders its combobox as a `<span>` whose `aria-label` it sets to the **selected value**, so the field's visible label is never announced (`getByRole('combobox', {name: 'Kind'})` → 0 matches). Passing `aria-label` at the call site does not help — the component overwrites it | Open, not started. Pre-existing and affects **every** Select (Kind, Frequency, and M5's Benchmark). Needs a `selectPt`-level fix wiring `aria-labelledby` to `FormField`'s label id, not a per-call-site patch. Both M7 call sites carry a comment pointing at the issue |
| [#64](https://github.com/amyotjl/PortfolioView/issues/64) | M8 | Export/import portfolios: 2 backend endpoints (download a portfolio file; upload + ingest it), 2 frontend buttons (Export / Import with file dialog), tests | Open, not started. User-filed 2026-07-21, outside the original backlog — decompose into backend/frontend/tester slices when picked up |

### Resolved (kept for traceability — don't reintroduce these)
- **Charts rendered at zero height** (M6, found and fixed in M7 2026-07-25) — see the
  "two traps" section above. The height lives on a wrapper div; moving it back onto
  `<VChart>` reinstates the bug silently.
- **`/register` unreachable by URL** (M5/M6, found and fixed in M7 2026-07-25) — see the
  "two traps" section above. Both guards are load-bearing.
- **Rejected optimistic transaction create lost the 422 and the user's input** (M7,
  2026-07-25) — the drawer closed then reopened, and reopening re-ran its seed watcher
  *after* the error was applied, resetting the form. It now closes only on success;
  don't reintroduce the up-front close.
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

## M8 design decisions worth not re-litigating
- **The contribution baseline is the window's opening value**, so the chart reads as growth
  *within the selected range*. `/candles` returns flows only for the requested range, so a
  cumulative sum of them is not lifetime contributed capital for any range starting after
  inception, and the pre-range cost basis is unknowable from that endpoint.
- **Negative growth renders as a third stacked band**, not a negative value: ECharts stacks
  negatives downward from zero, which would hang a loss below the axis instead of below the
  contributions line. Bands are `min(contributed, value)` + `max(0, growth)` +
  `max(0, -growth)`, with the total-value line plotted separately as the boundary.
- **The treemap reuses the by_sector donut's ordinal ramp on purpose** — same sector, same
  color in both allocation views. The usual "no value-ramp on nominal categories" rule is
  waived because a treemap's layout is itself magnitude-ordered (the same argument
  `theme.ts` already documents for the donut), and it survives 10+ sectors where the 8-hue
  categorical ceiling does not.
- **`/allocations`' `by_instrument[].sector` is a load-bearing join key**, not redundant
  data — it is the only way the hierarchy is derivable client-side. The contract test
  asserts it is byte-identical to the matching `by_sector` label.

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
- `/allocations`' `by_instrument` slices carry a `sector` label (added in M8 for #53) —
  PLAN.md only says "by_instrument + by_sector pies", so this is an additive extension,
  not a deviation.
- `US_EXCHANGES` recognized for transaction validation: NYSE, NASDAQ, AMEX, NYSE ARCA, NYSE
  MKT, BATS, IEX, CBOE.

## Running the e2e suite
```
docker compose up -d                             # the suite tests the RUNNING dev stack
docker compose --profile e2e run --rm e2e        # one command, headless
```
Full detail in [e2e/README.md](../e2e/README.md). Three things that will otherwise bite:
- The Playwright **image tag and the npm package version must match** (`v1.61.0-noble` /
  `@playwright/test` 1.61.0) — bump both together.
- Two host-authorization allowlists are required for the container to reach the app by
  service name: `server.allowedHosts: ['vite']` in `frontend/vite.config.ts` and
  `config.hosts << "vite"` in `config/environments/development.rb`. Remove either and the
  suite fails with an opaque 403.
- **Restart the vite container after editing a `.vue` file before re-running e2e.** Stale
  HMR state has repeatedly made a fixed bug look unfixed (and cost several debugging
  rounds in M7).
- Registration is rate-limited to **10 per 3 minutes**; the suite spends exactly one per
  run, so keep new specs API-driven.

## Environment facts worth knowing
- Real Tiingo/TwelveData/FMP keys are present in the dev `.env` and have been verified
  against real data: AAPL's actual 2020-08-31 4:1 split, real dividend history, real FMP
  sector/industry metadata. Demo-verification runs clean up their throwaway
  users/portfolios/transactions back to zero but **keep the fetched instrument/price/
  split/dividend/directory data cached** — AAPL, MSFT, SPY, QQQ, VTI don't need re-fetching
  (saves quota).
- DB host port is 5433 (see root [CLAUDE.md](../CLAUDE.md)).
