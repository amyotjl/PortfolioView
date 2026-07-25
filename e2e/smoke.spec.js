import { expect, test } from '@playwright/test'
import {
  INVITE_CODE,
  TEST_PASSWORD,
  benchmarkIdFor,
  createTransaction,
  uniqueEmail,
} from './helpers/api.js'

/**
 * The end-to-end smoke path (issue #51):
 *   register with invite code -> create a portfolio -> add a transaction via the
 *   symbol autocomplete -> candlestick renders -> toggle benchmark -> donuts render
 *
 * Thin by design. It proves the layers are wired together, not that the money math
 * is right — that lives in the Rails Minitest suite (see the testing-conventions
 * skill). So it asserts that data-driven UI appeared, and does not re-check values
 * the backend already has fixture tests for.
 *
 * SELECTOR NOTES (all established by inspecting the rendered DOM, per the
 * conventions — not read off the source):
 *  - Fields are addressed by ROLE + accessible name, which is also first on the
 *    project's query ladder. `getByLabel` is wrong here: FormField appends a
 *    `<span aria-hidden="true">*</span>` to required labels, so the label's text is
 *    "Shares *" and `getByLabel('Shares', { exact: true })` matches nothing, while
 *    the accessible name correctly stays "Shares" because the asterisk is
 *    aria-hidden. Verified: required fields resolve 0 by label and 1 by role.
 *  - PrimeVue's unstyled AutoComplete and DatePicker expose role `combobox`, not
 *    `textbox`.
 *  - The Kind/Frequency Selects are deliberately NOT asserted on: their accessible
 *    name is the selected value, not the field label (#65). The smoke path doesn't
 *    need them, and working around it here would hide the bug.
 *
 * Registration is rate-limited to 10 per 3 minutes, so this file registers EXACTLY
 * ONE user per run and builds everything else through the API.
 */

/** ECharts renders to <canvas>; a chart with data has a non-empty painted box. */
async function expectChartPainted(locator, name) {
  await expect(locator, `${name} canvas should be attached`).toBeVisible()
  const box = await locator.boundingBox()
  expect(box, `${name} should have a layout box`).not.toBeNull()
  expect(box.width, `${name} should have width`).toBeGreaterThan(50)
  expect(box.height, `${name} should have height`).toBeGreaterThan(50)
}

test.describe('smoke: register -> portfolio -> transaction -> dashboard', () => {
  test('the core journey works end to end', async ({ page }) => {
    const failures = []
    page.on('pageerror', (error) => failures.push(`pageerror: ${error.message}`))
    page.on('response', (response) => {
      const url = response.url()
      // 401 on the signed-out /session probe is expected; anything else 5xx/4xx
      // under /api is a real failure worth surfacing with the assertion.
      if (!url.includes('/api/v1/')) return
      if (response.status() >= 400 && !url.endsWith('/api/v1/session')) {
        failures.push(`${response.status()} ${response.request().method()} ${url}`)
      }
    })

    // --- 1. Register with the invite code, straight to the URL --------------
    // Loading /register directly (rather than clicking through from /login) is
    // deliberate: that path was broken by an eager authenticated-only query whose
    // 401 bounced the visitor to /login, and only a direct load catches it.
    await page.goto('/register')
    await expect(page.getByRole('heading', { name: 'Create account' })).toBeVisible()

    const email = uniqueEmail('smoke')
    await page.getByRole('textbox', { name: 'Email', exact: true }).fill(email)
    await page.getByRole('textbox', { name: 'Password', exact: true }).fill(TEST_PASSWORD)
    await page.getByRole('textbox', { name: 'Confirm password', exact: true }).fill(TEST_PASSWORD)
    await page.getByRole('textbox', { name: 'Invite code', exact: true }).fill(INVITE_CODE)
    await page.getByRole('button', { name: 'Create account' }).click()

    await expect(page.getByRole('heading', { name: 'Portfolios', level: 1 })).toBeVisible()
    await expect(page.getByText(email)).toBeVisible()

    // --- 2. Create a portfolio through the UI ------------------------------
    const benchmarkId = await benchmarkIdFor(page, 'SPY')

    await page.getByRole('button', { name: 'New portfolio' }).first().click()
    await page.getByRole('textbox', { name: 'Name', exact: true }).fill('Smoke portfolio')
    await page.getByRole('button', { name: 'Create portfolio' }).click()

    const card = page.getByRole('heading', { name: 'Smoke portfolio' })
    await expect(card).toBeVisible()

    // Adopt SPY as the benchmark via the API: the toggle later needs a benchmark,
    // and picking one from the styled Select is not the flow under test.
    const listResponse = await page.request.get('/api/v1/portfolios')
    const { portfolios } = await listResponse.json()
    const portfolio = portfolios.find((p) => p.name === 'Smoke portfolio')
    expect(portfolio, 'the created portfolio should come back from the API').toBeTruthy()

    const cookies = await page.context().cookies()
    const xsrf = cookies.find((c) => c.name === 'XSRF-TOKEN')
    const patch = await page.request.fetch(`/api/v1/portfolios/${portfolio.id}`, {
      method: 'PATCH',
      data: { name: 'Smoke portfolio', benchmark_id: benchmarkId },
      headers: {
        'Content-Type': 'application/json',
        'X-XSRF-TOKEN': decodeURIComponent(xsrf.value),
      },
    })
    expect(patch.ok(), await patch.text()).toBe(true)

    // Seed history the chart can actually plot. Dated in the past so it sits
    // inside the cached price window (a transaction dated after the newest close
    // would leave the candles empty).
    await createTransaction(page, portfolio.id, {
      symbol: 'AAPL',
      side: 'buy',
      shares: '10.0',
      price: '150.00',
      executed_on: '2026-05-01',
    })

    // --- 3. Add a transaction via the symbol autocomplete ------------------
    await page.goto(`/portfolios/${portfolio.id}/transactions`)
    await expect(page.getByRole('heading', { name: 'Transactions', level: 1 })).toBeVisible()

    await page.getByRole('button', { name: 'Add transaction' }).first().click()
    const drawer = page.getByRole('dialog')
    await expect(drawer).toBeVisible()

    // forceSelection means the value must come from the directory list, so the
    // suggestion has to be clicked — typing alone would leave the field empty.
    //
    // Type the FULL symbol. Results are capped at 20 and ordered exact > prefix >
    // name, and within prefix matches alphabetically — so 'MSF' returns
    // MSF, MSFAX, MSFBX … MSFN and MSFT never makes the cut. A partial query here
    // would fail for a reason that has nothing to do with the wiring under test.
    const ticker = drawer.getByRole('combobox', { name: 'Ticker' })
    await ticker.fill('MSFT')
    const suggestion = page.getByRole('option', { name: /^MSFT/ }).first()
    await expect(suggestion).toBeVisible()
    await suggestion.click()
    await expect(ticker).toHaveValue('MSFT')

    await drawer.getByRole('combobox', { name: 'Date' }).fill('2026-05-15')
    await drawer.getByRole('textbox', { name: 'Shares', exact: true }).fill('4')
    await drawer.getByRole('textbox', { name: 'Price', exact: true }).fill('400.00')
    await drawer.getByRole('button', { name: 'Add transaction' }).click()

    // The row lands in the table, and the undo toast confirms the optimistic path.
    // `exact` matters: the row's action buttons carry aria-labels like
    // "Edit buy of 4 MSFT on …", so a loose name matches two cells.
    await expect(page.getByRole('cell', { name: 'MSFT', exact: true })).toBeVisible()
    await expect(page.getByText('Transaction added')).toBeVisible()
    await expect(page.getByRole('button', { name: 'Undo' })).toBeVisible()

    // --- 4. Candlestick renders with data ----------------------------------
    await page.goto(`/portfolios/${portfolio.id}`)
    await expect(page.getByRole('heading', { name: 'Dashboard', level: 1 })).toBeVisible()

    // Stat tiles come from /summary, so their presence proves the analytics
    // endpoints answered before we look at the canvases.
    const performance = page.getByRole('region', { name: 'Lifetime performance' })
    await expect(performance).toBeVisible()
    await expect(performance.getByText('Current value')).toBeVisible()

    await expect(page.getByRole('heading', { name: 'Value, cash flow & drawdown' })).toBeVisible()
    const mainChart = page.locator('[_echarts_instance_] canvas').first()
    await expectChartPainted(mainChart, 'main dashboard chart')

    // The chart/table twin is the honest way to assert the SERIES has data —
    // canvas pixels are opaque to the DOM, but the table renders the same rows.
    // Scope to the ChartCard's own <section> root. Filtering on `div` instead would
    // also match a shared ancestor holding several cards, making the nested
    // Chart/Table buttons ambiguous.
    const chartCard = page
      .locator('section')
      .filter({ has: page.getByRole('heading', { name: 'Value, cash flow & drawdown' }) })
      .last()
    await chartCard.getByRole('button', { name: 'Table' }).click()
    await expect(page.getByRole('table').first()).toBeVisible()
    await expect(page.getByRole('row').nth(1)).toBeVisible()
    await chartCard.getByRole('button', { name: 'Chart' }).click()

    // --- 5. Benchmark toggle shows the benchmark line ----------------------
    const benchmarkSwitch = page.getByRole('switch', { name: 'Compare to benchmark' })
    await expect(benchmarkSwitch).toBeVisible()
    await expect(benchmarkSwitch).not.toBeChecked()

    const benchmarkRequest = page.waitForResponse(
      (response) =>
        response.url().includes('/candles') &&
        response.url().includes('benchmark=true') &&
        response.ok(),
    )
    await benchmarkSwitch.click()
    const benchmarkResponse = await benchmarkRequest
    await expect(benchmarkSwitch).toBeChecked()

    // Assert the benchmark series actually came back — a toggle that flips
    // without data would otherwise pass silently.
    const candles = await benchmarkResponse.json()
    expect(candles.benchmark, 'benchmark series should be present').not.toBeNull()
    expect(candles.benchmark.symbol).toBe('SPY')
    expect(candles.benchmark.values.length, 'benchmark should have points').toBeGreaterThan(0)
    await expectChartPainted(mainChart, 'main chart after benchmark toggle')

    // --- 6. Allocation donuts render ---------------------------------------
    const allocation = page.getByRole('region', { name: 'Allocation' })
    await expect(allocation).toBeVisible()
    await expect(allocation.getByRole('heading', { name: 'By instrument' })).toBeVisible()
    await expect(allocation.getByRole('heading', { name: 'By sector' })).toBeVisible()

    // Three ECharts instances on the dashboard: the linked chart + both donuts.
    await expect(page.locator('[_echarts_instance_]')).toHaveCount(3)
    const donuts = page.locator('[_echarts_instance_] canvas')
    await expectChartPainted(donuts.nth(1), 'by-instrument donut')
    await expectChartPainted(donuts.nth(2), 'by-sector donut')

    // Both tickers should appear in the by-instrument breakdown's table twin.
    const instrumentCard = allocation
      .locator('section')
      .filter({ has: page.getByRole('heading', { name: 'By instrument' }) })
      .last()
    await instrumentCard.getByRole('button', { name: 'Table' }).click()
    await expect(allocation.getByText('AAPL')).toBeVisible()
    await expect(allocation.getByText('MSFT')).toBeVisible()

    // --- 7. No unexpected API failures or uncaught errors ------------------
    expect(failures, `unexpected failures during the journey:\n${failures.join('\n')}`).toEqual([])
  })
})
