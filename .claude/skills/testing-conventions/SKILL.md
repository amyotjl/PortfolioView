---
name: testing-conventions
description: PortfolioView testing conventions across all three suites — Rails Minitest for the money math, Vitest for frontend units, Playwright (JS) for e2e. Use when writing or reviewing any test, choosing which layer should cover a behavior, or verifying an issue's acceptance criteria.
---

# PortfolioView Testing Conventions

## Which layer covers what

- **Rails Minitest (`test/`)** — all money math (CSF/split logic, valuation, benchmark simulation, recurrence), model validations, job behavior, API request specs against the frozen contract in `docs/PLAN.md`. The canonical fixtures live in PLAN.md's Verification section; every new domain behavior gets a fixture-level test here first.
- **Vitest (`frontend/`)** — pure functions only by default: chart option builders, tooltip formatters, zod schema parsing, composables. Component tests (Vue Testing Library) only for components with real logic (forms, autocomplete); presentation-only components are covered by e2e.
- **Playwright e2e (`e2e/`, JS — not Python)** — the smoke path: register → create portfolio → add transaction → candlestick renders → toggle benchmark → pies render. Keep e2e thin; it exists to prove the layers are wired, not to re-test logic.

Rule of thumb: test **behavior, not implementation**. A good test fails when the user-visible behavior breaks (false negatives are bugs in the suite) and does NOT fail when internals are refactored (false positives erode trust). Never assert on private methods, internal state shapes, or call counts unless the interaction *is* the contract (e.g. "provider adapter is not called twice for the same day").

## Rails/Minitest specifics

- Test names describe behavior: `test "sell dated before a 4:1 split ex-date uses pre-split share basis"` — when/with/without phrasing over method names.
- Use deterministic data builders (plain helper methods or fixtures) with **explicit dates** — never `Date.today` in a fixture; freeze time with `travel_to` around every date-sensitive test.
- Mock external HTTP (Tiingo/FMP) at the Faraday adapter boundary with recorded JSON fixtures; **never mock internal services** — if `Portfolios::Valuation` needs stubbing to test a controller, the controller test is at the wrong layer.
- Assert money with BigDecimal equality (`assert_equal BigDecimal("5360")`, not floats). A test must fail if Float math sneaks in.
- Cover the four case classes for every calculation: valid, invalid, edge (zero position, single trading day, empty portfolio), boundary (transaction ON the split ex-date, sell of the entire position).

## Vitest/Vue specifics

- Query ladder (strict order): `getByRole` → `getByLabelText` → `getByText` → `getByTestId` (last resort). If a test can't find an element by role, that's often an accessibility bug — fix the component, not the query.
- Use auto-retrying assertions (`await expect...`/`findBy*`) instead of manual waits; no `setTimeout` in tests.
- Factories are typed functions with `Partial<T>` overrides whose defaults parse against the real zod schemas — a schema change must break factories at compile/parse time.
- No shared mutable state between tests (`let` reassigned in `beforeEach` is a smell); build data inside each test.
- Network mocking through a single MSW-style handler layer keyed to the API contract, never per-test `fetch` monkey-patching.

## Playwright e2e specifics

- **Reconnaissance before action**: when writing or fixing a selector, first inspect the rendered DOM (screenshot or `page.content()`) — never guess selectors from source code.
- Wait for `networkidle` (or the specific response) before asserting on data-driven UI; charts render async after the API returns.
- Descriptive selectors: `getByRole`, `getByText`, stable ids — no CSS-path selectors that break on restyling.
- Each spec is independent and creates its own user/portfolio via the API (not the UI) for everything except the flow under test.

## TDD verification loop (when fixing a reported bug)

1. Write the failing test first and **run it — confirm it fails for the expected reason** (expect-red).
2. Apply the fix; run again — confirm it passes (expect-green).
3. Run the surrounding suite to catch collateral damage.
Skipping step 1 means the test may pass vacuously; a test that never failed proves nothing.

## Verifying an issue's acceptance criteria

Walk the criteria one by one and report a PASS/FAIL for each with the command + output that proves it. Report failures verbatim — never soften, never mark a failing criterion as passing, and say "not verified" explicitly for anything you could not run.
