# Frontend tests

This is the **Vitest unit layer**. It complements — never duplicates — the
Rails Minitest suite (money math, API contract) and the Playwright e2e smoke.
See `.claude/skills/testing-conventions` for the full project conventions.

## What belongs in Vitest (here)

Pure, fast, no real network:

- **Pure functions** — chart/option builders (e.g. `lib/sparkline.ts`), tooltip
  and number formatters (`lib/format.ts`), the API-error → form mapper
  (`lib/formErrors.ts`).
- **zod schema parsing** — valid **and** invalid payloads against the frozen
  contract (`types/*.spec.ts`).
- **Composables** — behavior of `use*` logic in isolation.
- **Component tests, only for components with real logic** — forms, inputs,
  a11y/validation wiring (e.g. `components/ui/FormField.spec.ts`). Use
  `@testing-library/vue` and the query ladder `getByRole` → `getByLabelText` →
  `getByText` → `getByTestId`. If an element can't be found by role, that's an
  accessibility bug in the component — fix the component, not the query.

Guidelines: test **behavior, not implementation**; no shared mutable state
between tests (build data in each test); use auto-retrying assertions
(`findBy*` / `await expect`) instead of manual waits; mock network at a single
handler layer keyed to the API contract, never per-test `fetch` patching.

## What does NOT belong here

- **Money / split / valuation / benchmark / recurrence math** → Rails Minitest.
  That is the authoritative layer for every BigDecimal calculation.
- **Presentation-only components** (cards, layout chrome, the sparkline SVG) →
  covered by the Playwright e2e smoke, not by component tests.
- **Full user journeys** (register → create portfolio → add transaction →
  candlestick renders → toggle benchmark → pies render) → Playwright e2e
  (`e2e/`, JS). Keep e2e thin: it proves the layers are wired, not the logic.

## Commands

```bash
npm run test           # run once (CI)
npm run test:coverage  # run once with a coverage report (text + html + lcov -> coverage/)
```
