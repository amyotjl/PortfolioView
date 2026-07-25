# Status (living document)

Last verified: 2026-07-25. **M0–M7 all merged and closed** (M4's follow-up defects #59/#60
fixed along the way). M8 is in progress on two unmerged branches: `m8/052-visualizations`
(#52/#53) and `m8/064-export-import` (#64). #63 and #65 are still open.

M7 also has an **e2e suite now** (`e2e/`, Playwright) — one command,
`docker compose --profile e2e run --rm e2e`, against the running dev stack. It has
already earned its keep: it caught that **every chart had been rendering at zero
height** since M6 and that **`/register` was unreachable by URL**. Run it after any
change to the dashboard, the shell, or auth routing — those two classes of bug are
invisible to Vitest and to the Rails suite.

Two specs now, each registering **exactly one** user per run (registration is rate-limited to
10 per 3 minutes, so keep new specs API-driven): `smoke.spec.js` and `transfer.spec.js`
(#64's export download + multipart import — a blob download and a multipart upload are both
invisible to Vitest and to fixture-based Rails tests). Set `E2E_SCREENSHOTS=1` to have
`transfer.spec.js` write `e2e/screenshots/*.png` for the "render it and look at it" check
below; a normal run leaves nothing behind.

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
| M8 | Extra visualizations | Contribution-vs-growth stacked area, sector treemap | 🟡 in progress — #52/#53 built on `m8/052-visualizations`; **#64** (portfolio export/import, user-filed) built on `m8/064-export-import`. Both awaiting the tester gate, neither merged |
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

## Traps that have already cost a debugging cycle each — read before touching charts or the shell
- **ECharts height must go on a WRAPPER, never on `<VChart>`.** vue-echarts injects an
  *unlayered* `x-vue-echarts { height: 100% }` rule into `<head>`, and unlayered CSS
  outranks Tailwind's `@layer utilities` — so `class="h-[560px]"` on the component is
  silently overridden and the chart collapses to 0px with no error anywhere. This is why
  no chart rendered from M6 until it was caught in M7.
- **Nothing may fetch authenticated-only data before the router guard resolves.**
  `App.vue` waits for a named route, and `usePortfoliosQuery` is `enabled` only when
  authenticated. Without both, a signed-out load of `/register` fires `/portfolios`, and
  the 401 handler redirects to `/login` — making the register page unreachable by URL.
- **Wait ~400ms after flipping `data-theme` before screenshotting.** Nearly every control
  carries `transition-colors`, so a screenshot taken immediately after
  `documentElement.setAttribute('data-theme', 'dark')` captures a half-applied palette that
  looks *exactly* like "this component doesn't theme" — a dark page with light buttons and
  panels. Found in #64: the fix was a settle wait, not a styling change. Verify with computed
  styles (`getComputedStyle(el).backgroundColor`) before believing a theming bug from a
  screenshot. Related: the modal mask correctly blocks clicks outside an open dialog, so the
  top-bar theme toggle is unreachable while one is open — poke the attribute instead.
- **PrimeVue's unstyled `Dialog` renders its title as a plain `<span>`.** So
  `getByRole('heading', { name: 'Import portfolios' })` matches nothing; address the dialog by
  its accessible name — `getByRole('dialog', { name: '…' })` — which *is* wired up correctly.
  Also note the header's X button has `aria-label="Close"`, so never label a footer button
  "Close" too (#64's became "Done").

## Open tracked defects & enhancements (outside the milestone they surfaced in)

| Issue | Milestone | What | Status |
|---|---|---|---|
| [#63](https://github.com/amyotjl/PortfolioView/issues/63) | M7 | `listed_instruments.name` is `null` on 100% of rows — Tiingo's bulk ticker file has no name column (by design in `Directory::ImportJob`); search/autocomplete can only ever match on symbol until enriched | Open, deliberately deferred out of M7 (the autocomplete ships symbol-only and already handles the null). Candidate fix: backfill from `instruments.name` (already fetched via FMP for any symbol the user has touched) without a real-time enrichment call. **Also worth fixing the relevance ordering while there:** results cap at 20 and prefix matches are alphabetical, so searching `MSF` returns `MSF, MSFAX, MSFBX … MSFN` and **MSFT never makes the list** — verified live |
| [#65](https://github.com/amyotjl/PortfolioView/issues/65) | M7 | a11y: PrimeVue's unstyled `Select` renders its combobox as a `<span>` whose `aria-label` it sets to the **selected value**, so the field's visible label is never announced (`getByRole('combobox', {name: 'Kind'})` → 0 matches). Passing `aria-label` at the call site does not help — the component overwrites it | Open, not started. Pre-existing and affects **every** Select (Kind, Frequency, and M5's Benchmark). Needs a `selectPt`-level fix wiring `aria-labelledby` to `FormField`'s label id, not a per-call-site patch. Both M7 call sites carry a comment pointing at the issue |
| [#64](https://github.com/amyotjl/PortfolioView/issues/64) | M8 | Export/import portfolios: 2 backend endpoints (download a portfolio file; upload + ingest it), 2 frontend buttons (Export / Import with file dialog), tests | **Implemented on `m8/064-export-import`, awaiting the tester gate.** Native round-trip JSON + broker holdings-CSV import, Export/Import buttons on the portfolios page, 101 Rails tests + 24 Vitest + a Playwright spec. See "#64 as built" below |

## #64 as built (export/import) — read before touching instruments or the importer

**The one fact that decided this feature's whole design:** the local `listed_instruments`
directory — Tiingo's published `supported_tickers` — contains **zero** Canadian rows and
**zero** CAD instruments (verified live: 99,043 USD / 7,154 CNY / 52 HKD / 4 AUD of 106,253;
no TSX/TSXV/CSE/CBOE-Canada exchange values at all). So "just relax the USD/US-exchange rule
in `Instruments::DirectoryResolver`" **does not work and is actively dangerous**:

- 7 of the 9 symbols in the user's real Wealthsimple report don't exist in the directory in
  any form, so relaxing the allowlist resolves nothing for them.
- Worse, three DO match — wrongly. `META` and `GOOG` in that report are **CAD-hedged TSX
  CDRs** and `FINN` is a **CBOE Canada ETF**; the directory's rows of those tickers are
  NASDAQ/PINK US securities. `instruments` is UNIQUE on `upper(symbol)` alone, so an
  unqualified import would bind all three to the wrong security — wrong currency, wrong price
  history, and for a CDR (a hedged fraction of the underlying) wrong quantities. Silent
  corruption, not a limitation.

The resolution: **`Portfolios::Transfer::SymbolQualifier`** gives non-US venues a
Yahoo/Tiingo-style suffix (`META` on `XTSE` → `META.TO`, `FINN` on `NEOE` → `FINN.NE`), so a
non-US listing can never alias a US ticker, and **`InstrumentResolver` trusts the file** for
identity the directory cannot supply. `DirectoryResolver` is **deliberately unchanged** —
typed input has only a bare string to go on, whereas an import file carries name/type/currency.
Do not "simplify" these two into one.

Consequence to keep stating to users: **imported CAD holdings have no price coverage**, so
their market value reads as zero. Cost basis is exact; market value needs a non-US price
source. That is a separate issue, not a bug in the importer.

- **Backend** (`app/services/portfolios/transfer/`): `Export`, `Import`, `NativeParser`,
  `HoldingsCsvParser`, `Detector`, `SymbolQualifier`, `InstrumentResolver`, plus the IR
  (`transfer.rb`: `Document` / `*Spec`, named `*Spec` so they can't shadow the AR models).
  Controller `Api::V1::PortfolioTransfersController`; serializer `PortfolioImportSerializer`.
- **`Import` is three-phase and the order is load-bearing**: plan names → resolve instruments
  **in the outer transaction** → one SAVEPOINT per portfolio. Instruments must NOT be created
  inside a portfolio's savepoint: a rollback there orphans the resolver's cache and the next
  portfolio writes a dangling FK. There is a regression test for exactly this.
- **Atomicity is per portfolio.** A half-imported portfolio reports a wrong cost basis with no
  outward sign, so a bad row rolls its portfolio back whole while siblings commit. Nothing is
  ever overwritten; a name collision renames (default) or skips.
- **`dry_run` runs the real import and rolls back** — same code path, validations and position
  replay included — so a preview can never disagree with the commit.
- **Transactions are inserted `executed_on` ASC, buys before sells.** The no-short-positions
  guard replays the rows committed *so far*, so a sell ahead of its covering buy is rejected
  even when the file is valid as a whole.
- **`Instrument#skip_provider_jobs`** (a plain attribute, not a thread-local — these are
  `after_create_commit`, which fire long after any block exits) suppresses the first-reference
  backfill for symbols the provider's own directory doesn't list. An **empty** directory stays
  permissive, because restoring into a freshly rebuilt database is this feature's headline use
  case and suppressing there would leave every instrument un-backfilled forever.
- **A holdings report is not a ledger.** `HoldingsCsvParser` synthesizes one opening buy per
  position, `price = book value / quantity` (NOT market price — that would erase all gain/loss),
  dated from the report's "As of" trailer. Total cost basis is preserved to the price column's
  6dp; purchase dates and individual lots are fiction, and the UI says so.
- **Frontend**: `types/transfer.ts`, `lib/download.ts` (`saveBlob`), `lib/importSummary.ts`
  (pure wording helpers), `composables/usePortfolioTransfer.ts`, `PortfolioImportDialog.vue`
  + `ImportReportPanel.vue`, Export/Import buttons on `PortfoliosView`. `api/client.ts` gained
  `apiDownload`/`apiUpload` over a shared `performFetch`, so a download/upload keeps the same
  CSRF header, 401 handler and error envelope as every other call — pointing `window.location`
  at the export URL would save a 401 envelope to disk instead of routing to `/login`.
- **Import warning strings must stay TENSE-NEUTRAL.** The same strings serve `dry_run`; the
  preview shipped reading "so this one **was imported** as …" for a rename, telling users their
  data had already been written. Locked by a test that greps every dry-run warning for
  `was/were imported`.

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
- `/portfolios/export` is a **file download** with no envelope, and `/portfolios/import` takes
  **multipart/form-data** rather than JSON — the only two endpoints that aren't JSON-in/JSON-out.
  Both are additive (#64 postdates PLAN.md's API contract), not deviations.

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
- Registration is rate-limited to **10 per 3 minutes**; each spec spends exactly one per run
  (two specs → two registrations), so keep new specs API-driven.
- To run one spec: `docker compose --profile e2e run --rm e2e bash -c "npm install
  --no-audit --no-fund >/dev/null && npx playwright test transfer.spec.js"`. Add
  `-e E2E_SCREENSHOTS=1` for `transfer.spec.js`'s visual-check PNGs (written to
  `e2e/screenshots/`, gitignored). **Don't write screenshots to `playwright-report/`** — the
  HTML reporter wipes that folder when the run ends.

## Environment facts worth knowing
- Real Tiingo/TwelveData/FMP keys are present in the dev `.env` and have been verified
  against real data: AAPL's actual 2020-08-31 4:1 split, real dividend history, real FMP
  sector/industry metadata. Demo-verification runs clean up their throwaway
  users/portfolios/transactions back to zero but **keep the fetched instrument/price/
  split/dividend/directory data cached** — AAPL, MSFT, SPY, QQQ, VTI don't need re-fetching
  (saves quota).
- DB host port is 5433 (see root [CLAUDE.md](../CLAUDE.md)).
