# Status (living document)

Last verified: **2026-08-05**. **All six issues that were open now have a finished branch
awaiting a gate** — see "M10: six issues, five branches" immediately below, which is the
section to read first. Nothing has been merged: the merge gate requires an independent tester
verdict and none of these has one. One NEW issue came out of that work and is **not** started:
[#79](https://github.com/amyotjl/PortfolioView/issues/79).

## M10: six issues, five branches, none gated (2026-08-05)

Not milestoned — these are the six issues open on 2026-08-05, worked in one session (#69 and
#70 share a branch: same file, same defect family). Each branch is off `7eda07d` (`main`)
except `m10/066-canadian-directory`, which continues the existing #66 work.
**None is merged and none has an independent verdict** — the gate counts below are the
author's own runs, which is exactly what the merge gate says not to trust.

| Branch | Issues | Gates run by the author |
|---|---|---|
| `m10/073-signout-clears-cache` | #73 | Vitest 313/313, `vue-tsc` clean, new e2e spec green; fix reverted → 4 unit specs and the e2e both fail for the right reason |
| `m10/069-070-pt-aria` | #69, #70 | Vitest 319/319, `vue-tsc` clean, e2e green; before/after measured in a real browser; 3 probes each failing only their own tests |
| `m10/075-internal-token-diagnostics` | #75 | Rails 807/807, RuboCop clean; boot line and 401 log verified live; 3 probes |
| `m10/074-unmount-actioncable` | #74 | Rails 802/802, RuboCop clean; `/cable` re-measured on a **full production build** in an isolated stack; 4 probes |
| `m10/066-canadian-directory` | #66 | Rails 851/851, RuboCop clean; classifier scored **35/35** against known truth over **789 real factors on 423 symbols**; 7 probes |

**Read the per-issue notes below before gating any of them** — several correct claims that
earlier issues or comments made incorrectly, and a gate that re-checks the original wording
rather than the corrected wording will disagree with the code for the wrong reason.

### #73 — the sign-out cache leak
`useQueryCache().clear()` **does not exist** in @pinia/colada 1.4.2; the issue assumed it.
`getEntries()` + `remove()` is the documented surface. Emptying happens inside
`authStore.clear()`, so the Sign-out button and `main.ts`'s 401 handler are both covered by
construction. `cancelQueries()` is kept but **no test pins it** (measured: deleting it leaves
all four specs green) — the comment says so; don't promote it to "load-bearing".
Keying caches by user id was considered and rejected.

### #69 / #70 — the PrimeVue ARIA family
Both measured before and after in a browser, since #69 shipped as source-reading only:
`group[name="Side"]` and `{name: "Invest by"}` were **0 → 1**, and `input-id="v-1-7"` was
leaking onto the `<div role="group">` as an invalid attribute (now suppressed). The Ticker
combobox's accessible description was `""` → now the hint, and the error after a failed
submit. **`DatePicker` had the same defect and it was measured, not assumed** — but only the
recurring drawer's "Ends on" can show it, because the transaction drawer's Date field has no
hint and a pre-filled date, so an absent describedby there is *correct*. A first measurement
attempt therefore looked like a clean bill of health.
Also: `fieldIds.spec.ts`'s docstring claimed to lock the `FormField` ↔ `pt.ts` contract; it
locks the pure functions only, and now says so. `smoke.spec.js`'s `Ticker`/`Date` lookups are
now `exact: true`, with a pin in `select-a11y.spec.js` that the exact form still resolves.

### #74 — Action Cable, decided: **don't mount it**
Option 1 of the three the issue lists, implemented as
`config.action_cable.mount_path = nil` rather than by unpicking `require "rails/all"`.
Nothing uses cable: `app/channels` holds only the generated connection, nothing broadcasts,
and the frontend has no `@rails/actioncable` dependency. Measured, with a real upgrade
handshake rather than a plain GET:

| | before | after |
|---|---|---|
| dev `GET /cable` | 404 text/plain | 404 (no route) |
| dev WS upgrade | **101 Switching Protocols** | **404 Not Found** |
| prod WS upgrade | — | **404 Not Found** |
| prod `/cable` body | — | not the shell (0 × `id="app"`) |
| prod `/portfolios/1` | — | 200, shell (1 × `id="app"`) |
| prod `db:prepare` from an empty volume | `app_production{,_cache,_queue,_cable}` | `app_production{,_cache,_queue}` |

Three traps for whoever gates it:
- **`"/cable"` had to join the SPA catch-all constraint.** While cable was mounted its own
  middleware answered a plain GET with 404 and the glob never saw the path; unmounted, the
  glob would answer `/cable` **200 with the Vue shell**. Removing that constraint entry
  regresses the exact property #58 measured.
- **`cable.yml` production is now `async`, not `solid_cable`.** `solid_cable` needs
  `db/cable_schema.rb`, which does not exist; declaring it without generating the schema
  recreates the empty-database half of this issue.
- **One correction to the issue:** it implies an unauthenticated client could connect.
  `ApplicationCable::Connection` *does* authenticate, and the before-measurement shows the
  101 followed immediately by `{"type":"disconnect","reason":"unauthorized"}`. The endpoint
  accepted the **upgrade** and then closed the **connection**. Lower severity than described;
  the contradiction (a broadcast reaching for a nonexistent Redis) still stood.

### #75 — the silent blank token
Two log-only signals: a boot line naming the state in **both** directions, and an INFO line
on the 401 path **only** when the token is blank. The 401 **response** is unchanged and a
test compares the blank-token and wrong-token responses byte for byte, headers included, with
only the four per-request headers excluded (`x-request-id`, `x-runtime`, `etag`, `date`) —
`content-length` deliberately compared. Enforcement was not attempted; #58 already settled
that with evidence (`${VAR}` and `${VAR:-}` both boot; `${VAR:?}` is ruled out by
docker-compose.yml's own header; unset is a legitimate choice).
The initializer gates on `Boot::Eligibility.process_kind`, **not** `.eligible?`, so an
operator who sets `DISABLE_BOOT_CATCH_UP` does not also lose this diagnostic.
Log strings are **ASCII on purpose** — an em dash mojibakes when the log is read with a
Windows ANSI codepage, observed live.

### #66 — the split classifier, rewritten (this is the important one)
**Three gate rounds rejected three rules, all thresholds on `(num, den)`.** The round-3
gate's diagnosis is the reason for the rewrite: *"(num, den) encodes the WRITTEN FORM of the
fraction, and Yahoo's written form is not a function of the event class."*

The rule now asks **the price series** instead. Yahoo divides every pre-ex-date close by the
factor, so its own series says whether the traded price actually moved: a genuine
split/consolidation leaves the adjusted series **continuous** (gap ≈ 1), while a reinvested
distribution — where units are issued and immediately consolidated, so neither the count nor
the price moves — leaves a step of **exactly the factor** (gap ≈ 1/ratio). That is physics,
not a threshold, and it is what separates `XCS.TO 9:10` (gap 1.1122 vs 1/ratio 1.1111 →
price-only) from `FTN.TO 11:10` (gap 0.9693 vs 0.9091 → a real subdivision) — two written
forms no rule on the pair can tell apart, whose truths are opposite.

**Where the evidence runs out: spin-offs.** A spin-off doesn't change the parent's share
count but *does* move its price, so its series is continuous too (`TRP.TO` gap 1.0015, as
continuous as AAPL's 4:1). **No price test can ever exonerate a spin-off.** What separates it
is the written form after all, but the other half of it: a *declared* split is a small-integer
exchange ratio (4:1, 11:10, 114:100 → 57/50) while a spin-off factor is *derived from market
prices* — an arbitrary decimal over a power of ten (1097:1000, 10000:9607). Hence
`MAX_DECLARED_DENOMINATOR`, applied **in lowest terms**.

Order, and every step is load-bearing:
1. ratio outside `NEAR_ONE_BAND` → **share-count, unconditionally.** No distribution or
   spin-off is worth 30% of a security, let alone the 100x of a `1:100`. This is what makes
   rounds 2 and 3 unrepeatable. It also absorbs a real Yahoo data-quality wrinkle: on thin
   TSXV/CSE listings the feed sometimes has **not** adjusted for its own factor
   (`RAGE.V 1:2` gap 2.0000, `VVTM.V 1:100` gap 99.9999), which the series test alone would
   read as price-only and turn into a 2x–100x share error.
2. denominator in lowest terms > 100 → price-only (market-derived decimal).
3. otherwise the series decides; **the nearer hypothesis wins.**
4. no bar on one side → share-count (what reaches here is a declared ratio, and with no
   earlier close there is no price to un-adjust either way).

There is deliberately **no "too close to tell" branch** — it would need an arbitrary default.
`GAP_MARGIN` only decides whether a call is *disclosed* as a close one.

**`classify_splits` runs BEFORE `unadjust!` and that ordering is the whole method.** Measured
after un-adjustment, the gap is a function of the factor being tested rather than evidence
about it, and `XCS.TO 9:10` flips to a split. A test pins the order.

**The evidence is reproducible** — `bin/rails yahoo:collect_factors` then
`yahoo:score_factors`, checked in precisely because round 3's Finding 3 was about
unverifiable sampling. A deterministic sweep (1,797 symbols → **789 distinct factors on 423
symbols**, against the gate's own 482 on 209) scored by driving the *shipped* method:

| | correct | wrong |
|---|---|---|
| this rule | **35** | 0 |
| round-3 shipped rule | 28 | 7 |

with 3 close calls in 789 and **0 factors outside the band suppressed**. Every case all three
rounds named is now correct.

Two known imperfections, in the source rather than papered over: `VOD 7:8` (a capital return
*and* a consolidation in one action; US-routed so Yahoo is never asked) and `GURU.TO 11:1000`
(no bar either side, so nothing observable supports either reading).

Also fixed here: **151 Canadian rows no venue ever issued** (`AAAJ.PR..V`, from a base symbol
already ending in a dot) are now dropped at the importer door — this file's own test had
*asserted* that shape as stored output. And the adapter test's header claimed the AAPL fixture
was "a cross-source agreement" pointing at Tiingo fixtures **that do not exist in this repo**;
the input is literally `124.81 / 4.0` with `124.81` asserted back. Reworded.

**Deliberately not fixed, now [#79](https://github.com/amyotjl/PortfolioView/issues/79):** the
other 913 multi-dot rows (`ACO.X.TO`) name real securities and fetch nothing because Yahoo
spells a class with a **dash**. Fixing it means changing `SymbolQualifier`, which is also
#68's identity source, so a user who already imported `ACO.X.TO` would get a **second**
instrument for `ACO-X.TO` — the exact failure `venue_sibling_for` exists to prevent. #79 also
carries the `DEFAULT_NON_US_SUFFIX` finding: **5,995 of 8,627 CAD listings (69%) are not on
the TSX**, so the `.TO` default is wrong for the majority (`FINN` → `FINN.TO` 404s;
`FINN.NE` is real).

---

Last verified before this session: 2026-07-30. **#68** (Wealthsimple *activity ledger* import, the third format)
and **#65** (Select a11y) both passed independent tester gates and **merged 2026-07-29** —
see "#68 as built", "#68 merge gate" and "#65 as built" below. **#63** (null instrument names
+ search relevance) **also passed its gate and merged**, as did its follow-up
[#71](https://github.com/amyotjl/PortfolioView/issues/71) (rank by listing age) after **three
gate rounds** — see "#71: two FAILs worth more than the feature". Two new a11y issues were filed from #65's gate:
[#69](https://github.com/amyotjl/PortfolioView/issues/69) and
[#70](https://github.com/amyotjl/PortfolioView/issues/70). **M9 is NOT unstarted** — see the
milestone table and "M9 is further along than this file claimed". **M0–M8 all merged** (M4's follow-up defects #59/#60 fixed along
the way). M8's three shipped issues — #52 contribution-vs-growth area, #53 sector treemap,
#64 portfolio export/import — each passed an independent tester gate on 2026-07-26 and were
merged that day. **M0–M9 are now ALL closed** — M9 finished 2026-07-31 with #54, #55, #56,
#57, #58 and #72. Still open: **#66** (Canadian securities — the currency model is DECIDED,
so it is blocked only on a data source) and four defects found by gates rather than by use:
**#69**/**#70** (a11y), **#73** (sign-out leaves the previous user's data on screen),
**#74** (ActionCable upgradeable while cable.yml declares Redis) and **#75** (a blank internal
token is diagnostically silent).

M7 also has an **e2e suite now** (`e2e/`, Playwright) — one command,
`docker compose --profile e2e run --rm e2e`, against the running dev stack. It has
already earned its keep: it caught that **every chart had been rendering at zero
height** since M6 and that **`/register` was unreachable by URL**. Run it after any
change to the dashboard, the shell, or auth routing — those two classes of bug are
invisible to Vitest and to the Rails suite.

**Three** specs now, each registering **exactly one** user per run (registration is
rate-limited to 10 per 3 minutes, so keep new specs API-driven — a full run now spends 3 of
that budget): `smoke.spec.js`, `transfer.spec.js` (#64's export download + multipart import,
plus #68's activity-ledger upload — a blob download and a multipart upload are both invisible
to Vitest and to fixture-based Rails tests), and `select-a11y.spec.js` (#65's accessible-name
assertions across three separate forms; needs no provider keys and no populated directory). Set
`E2E_SCREENSHOTS=1` to have `transfer.spec.js` write `e2e/screenshots/*.png` for the
"render it and look at it" check below; a normal run leaves nothing behind.

**If e2e fails at registration with "Bad Gateway", the `web` container is still booting** —
`docker compose restart vite` can take its dependency chain with it, and `bundle install` +
`db:prepare` make the restart slow. Check `curl -s -o /dev/null -w '%{http_code}'
http://localhost:3000/up` before blaming the spec; this looked exactly like the registration
rate limit once.

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
| M7 | Transaction/recurring UIs | Transaction form drawer, recurring-transactions page, Playwright e2e smoke | ✅ closed (#49–51). Its two spillover issues are now closed too: **#63** (+ follow-up #71) and **#65** |
| M8 | Extra visualizations + export/import | Contribution-vs-growth stacked area, sector treemap, portfolio export/import | ✅ merged and milestone closed 2026-07-26 (#52, #53, #64 — each tester-verified independently). **The milestone was closed with #63 and #65 still open and still attached to it** (GitHub shows M8 as 3 closed / 2 open). They were deliberately *not* re-milestoned to make the number look clean — both are M7 spillover tracked in the table below, and neither was ever in M8's scope. #66 is unmilestoned |
| M9 | Local deploy | Production Dockerfile/compose profile, boot catch-up sync, Sync-now button, persistence check | ✅ **merged and milestone closed 2026-07-31** (#54, #55, #56, #57, #58 — each independently gated), plus **#72** found by #54's gate. #58's runtime verification FAILED first on a defect that lived in the seam between two gated issues — see "M9 acceptance" below. This row said "not started" until 2026-07-29 and that was simply wrong |

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

- **Wait ~400ms after flipping `data-theme` before screenshotting.** Nearly every control
  carries `transition-colors`, so a screenshot taken immediately after
  `documentElement.setAttribute('data-theme', 'dark')` captures a half-applied palette that
  looks *exactly* like "this component doesn't theme" — a dark page with light buttons and
  panels. Found in #64: the fix was a settle wait, not a styling change. Verify with computed
  styles (`getComputedStyle(el).backgroundColor`) before believing a theming bug from a
  screenshot. Related: the modal mask correctly blocks clicks outside an open dialog, so the
  top-bar theme toggle is unreachable while one is open — poke the attribute instead.
- **Playwright's `getByRole` matches `name` as a case-insensitive SUBSTRING by default.**
  Pass `exact: true` in any accessible-name assertion. This nearly shipped a vacuous test in
  #65: the Benchmark Select's placeholder is "No benchmark", which *contains* "Benchmark", so
  the spec **passed against the unfixed bug** — only a mutation run exposed it. A repo-wide
  audit found Benchmark is the app's only label/placeholder overlap today, but `smoke.spec.js`'s
  `Ticker`/`Date` lookups are still non-exact (measured non-vacuous, same shape).
- **PrimeVue's unstyled controls are not labelable, so `<label for>` names nothing.** The
  `Select` combobox is a `<span>` (#65) — the same family as the `Dialog`-title trap below.
  `aria-label` at the call site cannot win, because the component overwrites it; `aria-labelledby`
  passes through untouched and outranks `aria-label` per the accname spec. Fix at the
  **`pt.ts` PT level** so every future instance inherits it, deriving ids through
  **`lib/fieldIds.ts`** — never per call site. Still outstanding in the same family:
  [#69](https://github.com/amyotjl/PortfolioView/issues/69) (`SelectButton` has *no* accessible
  name, and leaks `input-id` as an invalid DOM attribute) and
  [#70](https://github.com/amyotjl/PortfolioView/issues/70) (`AutoComplete`'s hint and validation
  error are never announced — `aria-describedby` lands on the wrapper).
- **PrimeVue's unstyled `Dialog` renders its title as a plain `<span>`.** So
  `getByRole('heading', { name: 'Import portfolios' })` matches nothing; address the dialog by
  its accessible name — `getByRole('dialog', { name: '…' })` — which *is* wired up correctly.
  Also note the header's X button has `aria-label="Close"`, so never label a footer button
  "Close" too (#64's became "Done").

## Open tracked defects & enhancements (outside the milestone they surfaced in)

**All six issues in this table now have a finished, ungated branch** — see "M10: five
branches ready to gate" at the top of this file, which supersedes the per-row status text
below wherever the two disagree. The rows are kept for the diagnosis each records.

| Issue | Milestone | What | Status |
|---|---|---|---|
| [#69](https://github.com/amyotjl/PortfolioView/issues/69) | — | `SelectButton` has no accessible name, and leaks `input-id` as an invalid DOM attribute | Branch `m10/069-070-pt-aria`. **Measured 0 → 1** for both instances; the issue shipped as source-reading only |
| [#70](https://github.com/amyotjl/PortfolioView/issues/70) | — | `AutoComplete`'s hint and validation error are never announced | Same branch. `DatePicker` had it too and was **measured**, not assumed |
| [#73](https://github.com/amyotjl/PortfolioView/issues/73) | M5 | Sign-out leaves the previous user's data on screen for the next user in the same tab | Branch `m10/073-signout-clears-cache`. Note `queryCache.clear()` does not exist in colada 1.4.2 |
| [#74](https://github.com/amyotjl/PortfolioView/issues/74) | — | ActionCable upgradeable in production while `cable.yml` declares a Redis that does not exist | Branch `m10/074-unmount-actioncable`. **Decided: don't mount it.** Re-measured on a full production build |
| [#75](https://github.com/amyotjl/PortfolioView/issues/75) | — | A blank `INTERNAL_API_TOKEN` is diagnostically silent | Branch `m10/075-internal-token-diagnostics`. Log-only; the 401 stays byte-identical and a test asserts it |
| [#79](https://github.com/amyotjl/PortfolioView/issues/79) | — | `SymbolQualifier`'s dot-versus-dash and `.TO`-default conventions leave ~913 CAD listings and every venue-less broker row fetching nothing | **Open, not started.** Split out of #66 because every fix changes instrument identity and could split one security across two instruments |
| [#63](https://github.com/amyotjl/PortfolioView/issues/63) | M7 | ✅ **MERGED and closed 2026-07-29** (see "#63 as built"), with follow-up #71 also merged. Was: `listed_instruments.name` is `null` on 100% of rows — Tiingo's bulk ticker file has no name column (by design in `Directory::ImportJob`); search/autocomplete can only ever match on symbol until enriched | Open, deliberately deferred out of M7 (the autocomplete ships symbol-only and already handles the null). Candidate fix: backfill from `instruments.name` (already fetched via FMP for any symbol the user has touched) without a real-time enrichment call. **Also worth fixing the relevance ordering while there:** results cap at 20 and prefix matches are alphabetical, so searching `MSF` returns `MSF, MSFAX, MSFBX … MSFN` and **MSFT never makes the list** — verified live |
| [#66](https://github.com/amyotjl/PortfolioView/issues/66) | none | Support Canadian-listed securities (TSX / TSX-V / CBOE Canada). Surfaced by #64: the user's real Wealthsimple report is entirely CAD | **NO LONGER BLOCKED — the branch `m10/066-canadian-directory` is finished and ungated.** A Yahoo EOD adapter is the data source the row below said was missing, the directory now carries 8,651 CAD rows, and the split classifier that failed three gates has been rewritten and scores 35/35 over 789 real factors. Read the #66 section at the top of this file. The rest of this row is the pre-2026-08-04 diagnosis, kept for the reasoning: **was blocked on ONE thing instead of two.** *Currency model — DECIDED 2026-07-30 by the project owner:* "assume everything is CAD; the fx rate and everything related to that will be for a later revision". So CAD is the reporting currency, no FX is built, and the question is **closed rather than solved** — don't re-litigate it. USD-priced holdings are deliberately NOT relabelled as CAD (the accounts hold both, and multiplying a USD close by a CAD share count and printing it as CAD would silently misstate a money figure). *Data source — STILL BLOCKING:* probed live 2026-07-25, **no configured provider serves Canadian daily history on its current tier** — Tiingo 404s with zero CAD rows, FMP returns 402 Premium for `.TO`, Twelve Data needs Grow+. History is what backfill/candles/valuation/summary/benchmarks are all built on, so TSX holdings still report market value as zero; cost basis is exact and the UI says so. Two things "assume CAD" does NOT reach: typed entry still can't find Canadian securities (the Tiingo directory has **zero** Canadian rows, so autocomplete cannot offer them — import is the working path), and `instruments` is still UNIQUE on `upper(symbol)` alone, so TSX `META` and NASDAQ `META` cannot coexist. **What unblocks this: a data source.** |

| [#68](https://github.com/amyotjl/PortfolioView/issues/68) | M8 | Import the Wealthsimple **activity ledger** (a real transaction history), the third import format alongside the native envelope and the holdings snapshot | ✅ **Merged 2026-07-29** after an independent tester PASS. Verified against the user's real 372-row export: 225 transactions, 3 portfolios, and a derived 3:1 split that makes the share counts reconcile with the independent holdings report. See "#68 as built" and "#68 merge gate" below |

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
  inside a portfolio's savepoint. **Corrected 2026-07-26 by the tester gate:** the failure mode
  is *not* a dangling FK, as this file and the class header both used to claim. Rails'
  `restore_transaction_record_state` nils the id of a record created in a rolled-back savepoint,
  so the cached `Instrument` reverts to `new_record?` and the next referrer's `belongs_to`
  autosave simply re-INSERTs it — the row is merely lost outright when the failing portfolio was
  its only referrer. The phase separation is still correct (one INSERT beats
  insert-rollback-reinsert), but the original regression test was **vacuous**: gutting
  `preresolve_instruments` to `nil` left all 572 tests green. The guard that actually
  discriminates is `an instrument is resolved in the OUTER transaction, so it survives its only
  portfolio failing` — its portfolio is the symbol's *only* referrer, so nothing can re-create
  the row. Verified red under that mutation and green restored.
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
  6dp; purchase dates and individual lots are fiction, and the UI says so. **Superseded for
  Wealthsimple users by #68's activity-ledger format** — see below; prefer the ledger.
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

## #68 as built (broker ACTIVITY-ledger import) — the third format

Wealthsimple also exports an **activity ledger**, which is a real transaction history.
**Prefer it over the holdings snapshot whenever a user has both**: `ActivitiesCsvParser`
keeps real trade dates, individual fills and closed positions, all of which
`HoldingsCsvParser` has to invent. Verified against the user's real 372-row export:
225 transactions across 3 accounts, and the resulting share counts reconcile with the
**independent holdings report** exactly on 13 of 14 positions (the 14th differs by one
day of a $10/day recurring buy, because the two exports have different cutoffs).

- **`CorporateAction/SUBDIVISION` is a split expressed as a SHARE DELTA**, not a ratio:
  `"ZEQT … Corrected quantity of shares by 182.0398"`, no price, no cash. The ratio is
  recovered from the position the ledger implies just before the ex-date —
  `(91.0199 + 182.0398) / 91.0199` = exactly 3. It becomes a **`SplitEvent`**, never a
  transaction (shares have a `price > 0` CHECK, and any invented price injects phantom
  cash into contributed capital). Dropping it leaves that position **10% short**.
- **Splits are written in Import's phase 2** — outer transaction, before any transaction
  row — for two independent reasons, both load-bearing: `split_events` is
  instrument-global so it must not sit inside a per-portfolio savepoint, and
  `Positions::Validator` reads splits **from the database** while replaying, so a sell of
  post-split shares is rejected as an oversell if the split isn't already there. There is
  a matched pair of tests: the sell passes with the split and fails without it.
- **There is no MIC/Exchange column**, so the venue signal is an `FX Rate:` marker in a
  TRADE's description — the broker converted currency, so the security isn't
  CAD-denominated and keeps its bare US ticker. The `currency` column is the **account's**
  currency (CAD on every row) and must never be read as the instrument's. This correctly
  separates US `QQQ` from CAD-listed `QQC`/`XQQ`, and correctly suffixes the CAD-hedged
  `META`/`GOOG` CDRs. The verdict is reached **per symbol over the whole file**, because
  only trades carry the marker while dividends and transfers for the same symbol do not.
- **`InstrumentResolver#venue_sibling_for`** stops one security becoming two instruments:
  the holdings report has a MIC and yields `FINN.NE`, the ledger has none and would mint
  `FINN.TO`. Matched on base symbol + same currency and **only when both sides are
  venue-suffixed**, so it can never collapse a US ticker into a non-US one. Whichever file
  is imported first wins the naming. Verified with both real exports: `FINN.NE` only.
- **`SecurityTransfer` rows are real positions** (~$51k in the sample), priced at
  `net_cash_amount / quantity`. Sign of `quantity` decides buy vs sell.
- **`Trade/SELL` carries a NEGATIVE `quantity`** — `abs` it, or the `shares > 0` CHECK fails.
- **Cash rows are skipped because there is no cash account**: dividends, deposits,
  interest, tax, fee reimbursements. The report states both consequences — contributed
  capital comes from trade cost rather than the deposit rows, and a dividend-funded buy
  reads as a new contribution, understating return. Auto-pairing a dividend to a later buy
  by amount was **rejected**: guessing wrong misstates a money figure, and the user can set
  `kind: dividend_reinvestment` per transaction.
- Warning volume is capped (`EXAMPLE_LIMIT`): the real file renames 39 tickers, and a
  39-item paragraph buries the two sentences that matter.

## #68 merge gate (2026-07-29) — evidence, and what it corrected

Independent tester, own worktree + own compose stack (`-p pv_t68`, all ports `[]`). Verdict
**PASS, merge**. Evidence:
[#68](https://github.com/amyotjl/PortfolioView/issues/68#issuecomment-5125542978). Rails
**626 runs / 2940 assertions / 0 failures** (run twice), Vitest **245/245 across 21 files**,
`vue-tsc` clean, RuboCop clean on all 14 changed files, `transfer.spec.js` green twice, live
zod 7/7, both themes screenshotted and verified by `getComputedStyle`.

**The matched pair is NOT vacuous, and this is how that was established.** Gutting
`create_splits` proves little — plenty of tests fail. The discriminating probe mutated
**order only**: `create_splits` moved *after* `write_portfolio`, so the split is still
created, just late. That failed **exactly one** test — "a sell of POST-split shares is
accepted" (`created` → `failed`) — which proves the test pins the real invariant
(`Positions::Validator` reads splits *from the database* mid-replay) rather than the split's
mere existence. 11 probes written from scratch, 11/11 discriminated.

**The reconciliation was re-derived twice, outside the app.** Once in PowerShell `[decimal]`
with no Rails code, once over real HTTP reading positions back out of Postgres. Both agree:
13/14 open positions exact to 8dp, RRSP META short 0.3106 = one $10 recurring buy at
$32.19/sh. Two things were checked rather than assumed: the match is **not vacuous** (all 14
rows carry non-zero counts on *both* sides; the other 42 pairs are closed positions, zero on
both sides, and excluded from the claim), and ZEQT's three-account match is **not a split
artifact** (FHSA's first ZEQT trade is 2026-05-20 and RRSP's 2026-01-08, both *after* the
2025-08-18 ex-date, so the instrument-global split legitimately doesn't touch them).

Findings that did **not** block the merge:
- **`smoke.spec.js` needs provider keys, not just a populated `listed_instruments`.** It
  fails in a fresh isolated stack because the worktree has no `.env`, so `daily_prices` is
  empty and the dashboard has no valuation series. A control run at pre-#68 `main` fails
  identically — environmental, not a regression. Same class of trap as the documented
  directory precondition; worth adding to `e2e/README.md`.
- **`Agent(..., isolation: "worktree")` creates the worktree on `main`, not on the current
  branch.** The tester had to `git checkout --detach 62ccf2a` to test the actual branch tip.
  **Any future gate dispatched this way must verify `git log -1` before trusting a result** —
  a tester who missed this would have gated the wrong tree and reported a confident PASS on
  code that isn't the branch.
- `HPS.A` → `HPS.A.TO` (safe and tested, but not Yahoo's `HPS-A.TO` convention).
- **The FX-Rate venue heuristic assumes a CAD account.** A US symbol traded inside a *USD*
  account carries no `FX Rate:` marker and would be suffixed `.TO` wrongly. Not reachable
  with this broker's export, but it is the load-bearing assumption of the whole venue model.
- The preview's `IMPORTED` outcome badge during a dry run is pre-existing from #64.

## #63 as built (directory search relevance + name enrichment)

**The search bug was a RANKING bug, not a matching bug** — `MSFT` was always in the result
set, it just lost. The only tie-break was alphabetical, results cap at `SEARCH_LIMIT` (20),
and mutual funds are **46% of the directory** (49,001 of 106,253) owning the dense 5-letter
X-suffixed namespace. So `MSF` returned `MSF, MSFAX, MSFBX … MSFRX` and MSFT never appeared.
Nothing errored; the row the user wanted was silently truncated. **A bounded result set makes
ranking a correctness concern, not a nicety** — any future cap-plus-weak-sort has this bug.

Ranking is now **match band → tradeable → asset class → symbol length → alphabetical**. The
`tradeable` tier reuses the exchange allowlist `DirectoryResolver` already enforces: a row on
NMFQS/PINK/OTCGREY **cannot be transacted at all**, so offering it above one that works only
earns the user a 422. The final alphabetical tier keeps the order total and the output
deterministic. Live: MSFT went from absent to **rank 8** through the real endpoint.
`US_EXCHANGES` moved onto `ListedInstrument` (it describes directory rows, and both the
resolver and search need it); `DirectoryResolver` aliases the old name so
`SymbolQualifier`'s reference is untouched.

- **`Directory::EnrichNamesJob`** copies `instruments.name` → `listed_instruments.name` in one
  set-based `UPDATE ... FROM` at **zero provider quota** — FMP already fetched those names.
  Coverage is deliberately partial and grows with the user's portfolio, which is exactly the
  set of symbols worth labelling. Enqueued after a successful directory import and after each
  metadata fetch; `IS DISTINCT FROM` makes re-runs no-ops that bump no timestamps.
- **Matching is asset-class aware, not symbol-only.** The real directory has `MSFC` as both a
  NASDAQ *Stock* and a BATS *ETF*, and `instruments` is UNIQUE on `upper(symbol)` alone — a
  symbol-only join would label an unrelated ETF with an equity's company name. Pairing
  `instrument_type` with `asset_type` keeps a name on the row it describes.
- **The weekly import would have erased all of it.** `upsert_all` overwrites every non-key
  column and every incoming row has `name: nil`. `COALESCE(EXCLUDED.name, …)` preserves
  enrichment while keeping a future name-carrying source authoritative. Note `on_duplicate:`
  **replaces** the clause `record_timestamps:` would have generated, so `updated_at` is set
  explicitly (that option still governs the INSERT path's `created_at`).
- No frontend change was needed: the serializer already emits `name` and zod already accepts
  `string | null`.

## #65 as built (Select accessible name)

**The root cause was not what the issue assumed.** PrimeVue does overwrite `aria-label`, but
the real defect is that the unstyled combobox is a **`<span>` — not a labelable element** — so
`FormField`'s `<label for>` was naming nothing at all. `aria-labelledby` has no fallback and
no override in `Select.vue`, passes straight through, and outranks `aria-label` per the
accname spec.

- **Fixed once, in `primevue/pt.ts`**: `selectPt.label` is now a callback deriving
  `aria-labelledby` from `props.inputId`. All three call sites (Kind, Frequency, Benchmark)
  and every future Select inherit it. `:input-id` is therefore **load-bearing for the
  accessible name** — the two M7 call sites carry a comment saying so.
- **New building block `lib/fieldIds.ts`** (`fieldLabelId`/`fieldHintId`/`fieldErrorId`) so
  `FormField` and `pt.ts` cannot drift on the id convention. Any new PT preset that must name
  a non-labelable control derives through it.
- **`aria-describedby` was fixed in the same pass** — it was being swept into `ptmi('root')`
  and landing on the wrapper `<div>`, so hint and error text were never announced on the
  control either.
- Gate measured both directions: by field label **0/0/0 → 1/1/1**, by selected value
  **1/1/1 → 0/0/0**. Five mutation probes, each failing a *specific* test. Note
  `fieldIds.spec.ts` stays green under a convention drift — it locks the pure functions only;
  **`selectA11y.spec.ts` is the real guard** (the spec's own docstring overclaims this).
- Third e2e spec added (`select-a11y.spec.js`), so a full suite run now spends **3** of the
  10-per-3-minutes registration budget. It needs no provider keys and no populated directory.

## #71: two FAILs worth more than the feature (2026-07-30)

Search now ranks on a sixth tier, `start_date`. The feature is small; the two rejected
rounds are the part worth reading, because both failures were of a kind that passes every
test suite.

**Round 1 — the intuitive tier order was the wrong one.** Age placed *before* symbol length
made ARM, NET, RDDT and SOFI unreachable at two characters. Not anecdotal: across all 676
two-letter prefixes it pushed post-2020 rows in the top-20 from 42.4% to 31.7%, against a
55.5% population share. `ARMH`, a 1998 ADR still carrying recent prices (so the liveness tier
counts it live), outranked the 2023 `ARM`. **Age is a proxy for prominence and on its own it
penalises exactly the recent listings people search for.** Moving it *after* length fixes it,
and the reason that order is safe is structural, not statistical: it is a strict refinement of
the previous ordering, so no row can cross a length boundary — 0 of 676 prefixes change their
top-20 length profile, against 376 of 676 the other way.

**Round 2 — the documented cost was wrong by ~34x.** The comment said the tier "loses only
SOFI". That came from a 76-ticker list chosen by the person who wrote the tier. An exhaustive
prefix sweep found **1,617** symbols displaced from a 2-character top-20, **1,219** of them
live/tradeable/non-fund/≤4 chars — SNAP, MTCH, MBLY, ASAN, CELH, VICI, ARCC and more. The
tester explicitly did **not** ask for the SQL to change; it asked for the cost to be written
down truthfully, because a confidently-wrong figure in a file agents are told to trust is the
exact failure the issue existed to delete. The justification was wrong too, even though the
conclusion was right: the coverage numbers used to argue for it do not replicate on a larger
list (358 tickers: 280 vs 279, a wash).

**Transferable rules earned here:**
- **A hand-picked ticker list always flatters whoever picked it.** For anything ranked against
  the directory, sweep exhaustively or state plainly that you sampled.
- **A capped result set makes ordering a correctness concern.** A weak sort does not return a
  wrong row, it silently omits the right one — invisible to every assertion that checks
  content rather than presence-within-the-cap.
- **Commit before running mutation probes.** `git checkout --` to restore a probe destroys
  uncommitted work in the same file; this cost real work twice in one session.

Three smaller things the same gates found and fixed: `index_listed_instruments_on_end_date`
was never used (a b-tree cannot serve a `CASE` in `ORDER BY`; `idx_scan` delta 0 over 138
uncached searches) and is dropped; search really costs **~13ms**, not the 0.2–0.3ms #63
reported (that was a `rails runner` query-cache artifact — not a regression, and the ticker
AutoComplete debounces at 250ms); and `Instruments::DirectoryResolver` had **no test file at
all**, which is why its row choice could be non-deterministic without anything noticing.

## M9 acceptance (#58, 2026-07-31) — the milestone gate earned its place

#58 **FAILED first**, on a defect no per-issue gate could have caught, which is the whole
argument for verifying the assembled system rather than only its slices.

**`docker-compose.yml` passed `INTERNAL_API_TOKEN` to the dev `web` service only.** `web-prod`
never received it. `Api::Internal::BaseController` fails closed on a blank var, so in
production `POST /api/internal/jobs/daily_sync` answered **401 to the correct token exactly as
it does to a wrong one** — indistinguishable from a token mismatch, so it read as operator
error. Setting it in `.env` did nothing, because compose did not forward it. **#56 gated the
endpoint. #54 gated the image. The bug lived in the wiring between them.** Isolated with a
control (adding only that one line to an override → 202 while a wrong token still 401'd), so
#56's code was correct throughout. Fixed in `ef49833` and re-verified against the shipped
config, with an override carrying only a `ports` block.

**Don't "harden" the `:-` default into a required variable.** Probed directly: `${VAR}` and
`${VAR:-}` **both** resolve to an empty string and both boot — the bare form buys a stderr
warning and nothing else. Real enforcement needs `${VAR:?}`, which this compose file's header
already rules out, because interpolation runs at **parse time for every service including
profiled ones** and would break a plain `docker compose up` for the dev stack. Unset is a
legitimate steady state (the Sync-now button uses session auth) and was confirmed a clean
disable, not a degraded boot. The residual diagnostic gap is tracked as #75.

Other evidence worth keeping: persistence proved by a **byte-identical snapshot hash** across
`down`/`up` over 43,320 price rows; boot catch-up tested by constructing the *degenerate*
state (`latest == last_trading_day`) that only the wall-clock predicate catches; and every
`enqueued=` log line cross-checked against the queue, per #72's warning that the line
under-reports.

Two doc claims it measured as false, both corrected: a fresh database reports
**`instruments_behind: 3`**, not 0 (seeded benchmarks are referenced with a NULL
`latest_price_on` — the service was right, `API_SHAPES.md` *and* `freshness.rb`'s docstring
were wrong), and a smoke failure can mean a **backfill still in flight** rather than absent
keys (a real Tiingo 429 rescheduled, retried, and passed).

## M9 gate evidence (2026-07-30) — split three ways by coupling

Not one gate over five issues, and not five gates. Split by **coupling**: `Prices::Freshness`
unifies the staleness predicate that #55 and #56 both consume, so gating those apart would
have gated a refactor against callers that weren't merged. Branches were built by
cherry-picking the original commits onto current `main` (all applied cleanly) and each was
verified green *before* a gate run was spent on it.

**Gate A — #54 production image (PASS).** The `chmod +x bin/*` fix was the one claim
unverifiable from this machine: every `bin/` script is recorded mode `100644` because the repo
is developed with `core.filemode=false`, and building from the Windows checkout masks it. The
tester proved it instead of reasoning about it — `git archive HEAD` emits a tarball carrying
`-rw-rw-r--`, and `docker build - < ctx.tar` is then a clean Linux checkout exactly:
**without the fix, exit 126 `permission denied` on the entrypoint; with it, it runs.** The
full production build was re-run from that clean context. It also refused to accept
200-with-HTML as proof of the deep link and checked **Vue actually mounts** in headless
Chromium.

**Gate B — #55/#56 + the staleness refactor (PASS).** Equivalence was proven, not assumed: the
tester reconstructed the *pre-refactor* predicate and ran it beside the new one across 25
cache-state × wall-clock combinations. Its first probe **failed**, catching a real reference-day
divergence when the cache is ahead of the wall clock (reporting-only, unreachable without
future-dated rows). 14 probes, each against a `cmp`-verified pristine tree. Live evidence
included a server boot with `app_development` **dropped** and a full auth attack matrix on the
internal route (wrong scheme, wrong header, query param, session-only → all 401, byte-identical
envelope, no timing oracle).

### "#59" is not the staleness issue — do not cite it that way
**#59 is a CLOSED M4 issue** about token-less non-GET requests returning 422 HTML. The M9
staleness unification has **no GitHub issue at all** (M9 covers #54–#58); the original author
labelled it #59 anyway and later sessions repeated the error into branch names, dispatch
prompts and this file. Five source comments were corrected in `b9296e3`. **`base_controller.rb`'s
`#59` is CORRECT** and was deliberately left alone — it genuinely refers to the
`ErrorsController` work, so a blanket find-and-replace breaks a true reference while fixing
false ones.

### Non-blocking findings carried forward
- **`Boot::CatchUp` bypasses `SyncTrigger`'s 10-minute lease** — 5 calls enqueue 5 jobs, and a
  second real boot enqueues again. Bounded by `PriceProvider::Budget` (Tiingo 1000/day, 50/hr)
  so the provider **cannot** be stormed; the cost is queue churn. This is precisely why a
  directory import must not be dropped into boot catch-up unguarded (see #72).
- **A permanently unpriceable referenced instrument makes every boot enqueue, indefinitely** —
  the imported-CAD-portfolio case. The old MAX predicate didn't fire here; the new COUNT does.
  Deliberate, but unbounded in time.
- **Puma cluster mode would multiply the catch-up.** `config/puma.rb` has no `workers` and no
  `preload_app!` today, so it fires once. If that ever changes without `preload_app!`, every
  worker runs it — worth checking during #58.
- **Blank provider keys are NOT silent** — jobs are discarded at ERROR level naming the missing
  variable.
- **The SPA catch-all's route constraint was vacuously covered** (deleting it broke zero tests).
  Its `/api` half is genuinely redundant — the `/api/*` JSON-404 route is declared *above* the
  glob — but `/rails/` has no earlier guard, so without the lambda the glob swallows
  framework-reserved paths and answers 200 with the shell. Pinned in `4cac915`.
- **`app_production_cable` is created empty** (no `db/cable_schema.rb`) while
  `config/cable.yml` production still declares `adapter: redis`, contradicting the no-Redis
  invariant. Nothing in M9 reaches for ActionCable, so it doesn't bite yet.

### For whoever picks up #57 or #58
- **`/api/v1/sync` needs TWO zod schemas.** `GET` and `POST` share the `sync` wrapper but have
  different inner key sets, and on a fresh install `latest_price_on` and `last_trading_day` are
  **both null together** with `stale: true`. A schema assuming non-null strings rejects every
  response on a fresh deploy — the same class of bug as the `/instruments/search` nullability
  defect caught before merge in M5.
- **Dev uses `:memory_store`**, so the sync dedupe lease is per-process: clearing `CLAIM_KEY`
  from `rails runner` does not clear the running server's, and manual Sync-now testing sees a
  sticky `pending: true` for 10 minutes. Production (`:solid_cache_store`) is correct.

## M9 is further along than this file claimed (discovered 2026-07-29)

**Prepared 2026-07-29:** `m9/integration-rebased` (`eb54d6e`) merges `m9/integration` onto
post-#68 `main`. It merged **cleanly, no conflicts**, adds **no migrations**, and the full
Rails suite is green on it — **769 runs / 3508 assertions / 0 failures**. So the remaining
M9 work is *gating*, not integration. It is deliberately **not** merged: none of #54–#57 or
#59 has an independent tester verdict, and the merge gate applies to all five.


`docs/STATUS.md` said "M9 not started" and listed #55–#58 as blocked on #54. **Both were
wrong**, and the error survived several sessions because everyone trusted this file over
`git branch`. Verified by inspection today:

| Branch | Contains |
|---|---|
| `m9/054-prod-image` | #54 production Dockerfile + compose profile + SPA catch-all |
| `m9/055-boot-catchup` | #55 boot catch-up sync initializer |
| `m9/056-internal-sync` | #56 token-guarded internal sync endpoint + session-authed Sync now |
| `m9/057-sync-now` | #57 Sync-now button + freshness card |
| `m9/059-unify-staleness` | #59 one staleness predicate (`Prices::Freshness`) |
| **`m9/integration`** | **all five merged — 43 files, 3,661 insertions** |

All dated 2026-07-26, all unmerged, none tester-gated. The leftover
`pv_t58_pgdata_production` volume and a `pv_t58-web-prod-1` container that exited **143**
(clean SIGTERM) corroborate that the production stack really did boot at the time.

**`m9/integration` is based on `c1ef462`, i.e. before #68 merged**, so it needs a merge into
current `main` either way. A second #54 candidate exists on `m9/054-production-image`: the
same two commits cherry-picked onto post-#68 `main`, plus one real fix — every `bin/` script
is recorded mode `100644` because this repo is developed with `core.filemode=false`, so a
build from a clean **Linux/CI** checkout dies with `permission denied` on the entrypoint.
That claim is *reasoned, not observed* (it needs a Linux build host).

**Lesson for this file:** when it disagrees with `git branch -a --sort=-committerdate`,
git wins. Check both before declaring a milestone unstarted.

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
- `/portfolios/export` is a **file download** with no envelope, and `/portfolios/import` takes
  **multipart/form-data** rather than JSON — the only two endpoints that aren't JSON-in/JSON-out.
  Both are additive (#64 postdates PLAN.md's API contract), not deviations.

## M8 merge gate (2026-07-26) — evidence and the small things it turned up

Two independent testers, one per branch, each in its own worktree and its own compose stack
(`-p pv_t52` / `-p pv_t64`, all ports overridden to `[]`). Full evidence lives in the issue
comments: [#52](https://github.com/amyotjl/PortfolioView/issues/52#issuecomment-5084239598),
[#53](https://github.com/amyotjl/PortfolioView/issues/53#issuecomment-5084239660),
[#64](https://github.com/amyotjl/PortfolioView/issues/64#issuecomment-5084236838). Both
verdicts: **PASS, merge**. Between them: Rails 442 and 572 runs green, Vitest 213 and 182,
`vue-tsc` clean, e2e green, zod schemas validated against **live** captures (10/10 and 7/7,
no nullability surprises), and 12 mutation probes that all failed for the predicted reason.

Neither tester saw the *other* branch, so the merged result was re-verified on `main` after
both merges: **Rails 573 runs / 2664 assertions / 0 failures**, **Vitest 241/241 across 21
files**, `vue-tsc` clean. (573 = 572 + the phase-2 guard added in `a3801c3`.)

Findings that did **not** block the merge but are worth knowing:
- **`charts/treemap.ts:115-117` derives a displayed money string with float math**
  (`reduce(… Number(r.value)).toFixed(2)`) instead of `lib/money.ts`. Only reachable if a
  sector appears in `by_instrument` but not `by_sector`, which a contract test pins as
  impossible — so it is latent, not live. Fix when touching that file: `toCents` +
  `centsToDecimalString`.
- **Live money strings are not always 2dp** — real responses include `"7296.0"` and
  `"10626.2"`. `lib/money.ts#toCents` handles it; any new derivation that assumes two decimal
  places will mis-scale by 10×.
- **The "ETF / Fund" sector bucket is rarer than it looks.** FMP returns a real sector for
  broad-market ETFs (VTI → `"Financial Services"`), so `SECTOR_FALLBACK` only appears for
  instruments with genuinely absent metadata. A test that assumes "ETF ⇒ fallback" will pass
  vacuously — the tester hit exactly this and had to NULL the column to exercise the path.
- **`ChartCard`'s Chart/Table toggle resets to Chart on refetch.** Pre-existing, untouched by
  M8, not filed.
- Counts in the original #64 commit message understate: it is **130** Rails tests and **28**
  Vitest, not 101 and 24.
- **`apiUpload`'s CSRF header has no unit-level guard** — dropping `withCsrf` keeps Vitest
  fully green and is caught only by e2e. Correct layer per the testing conventions, but don't
  rely on Vitest to protect it.

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
- **`listed_instruments` must be populated — but since #72 the app provisions it itself.**
  Boot::CatchUp now enqueues `Directory::ImportJob` when the table is empty, so a brand-new
  database heals without intervention. **There is still a ~7-second race**: the import measured
  6.8–7.1s live, so an e2e run started immediately after boot can still hit
  `AAPL … is not a recognized US-exchange symbol`, which looks like an app bug and is not one.
  Wait for the boot log's `directory_unprovisioned=true; enqueued=Directory::ImportJob` line to
  be followed by the import's own completion, or just run `Directory::ImportJob` yourself
  (~106,300 rows, keyless, no quota cost) before the suite.
- **Do NOT read `enqueued=nothing` in the boot log as proof nothing was enqueued.** The import
  is enqueued *first*, so a later `perform_later` failure leaves the log line understating what
  is actually queued (found by #72's gate).
- **`smoke.spec.js` additionally needs provider keys — or a backfill that has FINISHED.** With
  no `.env`, `daily_prices` is empty, the dashboard has no valuation series, and the spec
  fails at `smoke.spec.js:185` in a way that looks like an app bug. Confirmed environmental
  during #68's gate by a control run at pre-#68 `main` that failed identically. #58 widened
  this: with keys present it can *still* fail if a backfill is mid-flight. A real Tiingo **429**
  produced `RateLimited; rescheduling in 60s (attempt 1)`, both retries then succeeded, and the
  identical spec passed on re-run. So a smoke failure on a fresh deploy means "prices aren't
  there **yet**" at least as often as it means "prices can't be fetched" — check the job log
  before concluding anything.
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
