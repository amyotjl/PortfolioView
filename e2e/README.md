# End-to-end smoke suite

Playwright (JS), the third and thinnest test layer. It exists to prove the layers
are **wired together** — not to re-test logic. See
`.claude/skills/testing-conventions` for which layer owns what.

- Money/split/valuation/benchmark math → Rails Minitest (`test/`)
- Pure functions, schemas, form logic → Vitest (`frontend/src/**/*.spec.ts`)
- The one user journey → here

## Run it

```bash
docker compose --profile e2e run --rm e2e
```

That is the whole command. The `e2e` service is behind a compose profile, so a
plain `docker compose up` never starts it.

The **dev stack must already be running** (`docker compose up -d`). The suite
deliberately does not manage its own server: it tests the real dev stack, and a
Playwright `webServer` would boot a second one that collides with it.

Other useful invocations (all from inside the container):

```bash
docker compose --profile e2e run --rm e2e bash -c "npx playwright test --reporter=line"
docker compose --profile e2e run --rm e2e bash -c "npx playwright test --debug"
```

## Why it runs in a container on the compose network

`frontend/node_modules` is Linux-only (root `CLAUDE.md`: never run npm on the
host), and Playwright's bundled browsers must match its npm package version — so
the service pins `mcr.microsoft.com/playwright:v1.61.0-noble` against
`@playwright/test` 1.61.0. **Bump both together or Playwright refuses to start.**

It joins the compose network and reaches `vite:5173` directly, publishing no host
ports (3000/5173/5433 belong to the dev stack).

Two host-authorization guards had to allow that service name, and both are
required — removing either breaks the suite with a confusing 403:

- `frontend/vite.config.ts` → `server.allowedHosts: ['vite']` (Vite's
  DNS-rebinding guard rejects the `Host: vite:5173` header)
- `config/environments/development.rb` → `config.hosts << "vite"` (Vite proxies
  `/api` with `changeOrigin: false`, so Rails sees that same Host)

## Constraints worth knowing before adding a spec

- **Registration is rate-limited to 10 per 3 minutes.** `smoke.spec.js` registers
  exactly ONE user per run so the required 3 consecutive runs stay well inside the
  budget. A new spec should create its user through the API and, ideally, reuse a
  session rather than adding registrations.
- **`retries: 0` and `workers: 1` are deliberate.** Retries would mask the flakes
  the "3 consecutive clean runs" criterion exists to detect, and parallel workers
  would race the registration budget.
- **No cleanup.** Each run leaves a throwaway user/portfolio behind. That is
  intentional — cached instrument/price data is expensive to refetch (see
  `docs/STATUS.md`), and unique emails keep runs independent.
- **Date the seeded transactions in the past.** The candles only cover the cached
  price window; a transaction dated after the newest close leaves the chart empty.

## Selectors: look before you write

The conventions require inspecting the rendered DOM before writing a selector.
Three findings from doing that, all of which cost a debugging cycle:

1. **Use `getByRole`, not `getByLabel`, for form fields.** `FormField` appends
   `<span aria-hidden="true">*</span>` to required labels, so the label text is
   `"Shares *"` and `getByLabel('Shares', { exact: true })` matches **nothing**.
   The accessible name stays `"Shares"` because the asterisk is `aria-hidden`.
2. **PrimeVue's unstyled AutoComplete and DatePicker are `combobox`**, not
   `textbox`, and `getByLabel` does not resolve them at all.
3. **Scope card-local controls to `section`.** `ChartCard`'s root is a `<section>`;
   filtering on `div` matches a shared ancestor and makes the per-card
   Chart/Table buttons ambiguous.

Useful one-liner while investigating: `console.log(await page.locator('body').ariaSnapshot())`.

## What this suite has already caught

Both were invisible to the unit layers and are why the assertions below are shaped
the way they are:

- **Charts rendered at zero height everywhere.** vue-echarts injects an
  *unlayered* `x-vue-echarts { height: 100% }` rule, which outranks Tailwind's
  `@layer utilities` — so `h-[560px]` on the component was silently overridden and
  every chart collapsed to 0px, with no error anywhere. `expectChartPainted()`
  asserts a real painted box specifically so this cannot come back; a unit test
  cannot see it, because it is real layout.
- **`/register` was unreachable by URL.** An eager authenticated-only query fired
  while signed out and its 401 bounced the visitor to `/login`. The spec loads
  `/register` directly rather than clicking through from `/login`, which is the
  only way to catch it.
