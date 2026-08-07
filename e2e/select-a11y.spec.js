import { expect, test } from '@playwright/test'
import {
  INVITE_CODE,
  TEST_PASSWORD,
  createPortfolio,
  primeCsrf,
  uniqueEmail,
} from './helpers/api.js'

/**
 * Accessible names for every PrimeVue Select in the app (issue #65).
 *
 * THE ACCEPTANCE CRITERION, verbatim: `getByRole('combobox', { name: '<visible
 * label>' })` must resolve to exactly ONE element for all three Selects. Before
 * the fix it resolved to ZERO for all three — PrimeVue's unstyled Select renders
 * its combobox as a `<span>`, which `<label for>` cannot name, so the component
 * fell back to announcing the SELECTED VALUE as the field's accessible name.
 *
 * This has to live in e2e rather than Vitest: the bug is in the accessible-name
 * COMPUTATION over a real rendered tree, and the fix routes through PrimeVue's
 * pass-through merge order. A Vitest guard exists too
 * (frontend/src/primevue/selectA11y.spec.ts) and is the faster feedback loop,
 * but only a real browser proves what a screen reader would actually announce.
 *
 * Every assertion uses `toHaveCount(1)` rather than `toBeVisible()` on purpose:
 * a count is what the issue specifies, and it fails loudly on the "matched 2
 * things" regression that a visibility check would sail past.
 *
 * `exact: true` IS LOAD-BEARING, not decoration. Playwright matches the `name`
 * option as a case-insensitive SUBSTRING by default, and the Benchmark Select's
 * placeholder is "No benchmark" — which contains "benchmark". A non-exact query
 * therefore matched the *unfixed* control by its placeholder-derived aria-label
 * and this whole spec passed against the bug. Measured against reverted code:
 * non-exact reported Benchmark:1 Kind:0 Frequency:0, exact reported 0/0/0.
 * Drop `exact` and the Benchmark case silently stops testing anything.
 *
 * Registration is rate-limited to 10 per 3 minutes, so this file registers
 * EXACTLY ONE user and builds everything else through the API.
 */

/** The three Selects, by the visible label each must announce. */
const KIND_LABEL = 'Kind'
const FREQUENCY_LABEL = 'Frequency'
const BENCHMARK_LABEL = 'Benchmark'

/** #69: the two SelectButtons, by the visible label each must announce. */
const SIDE_LABEL = 'Side'
const INVEST_BY_LABEL = 'Invest by'

/** #70: the Ticker AutoComplete's hint, which must be ANNOUNCED, not just shown. */
const TICKER_HINT = 'Search the local directory — no API quota is used.'
const TICKER_ERROR = 'Pick a ticker from the list'

/** Accessible-name lookup, always exact — see the note above. */
function comboboxNamed(scope, name) {
  return scope.getByRole('combobox', { name, exact: true })
}

/**
 * #69: SelectButton's root is `<div role="group">`. `exact: true` for the same
 * reason as everywhere else in this file.
 */
function groupNamed(scope, name) {
  return scope.getByRole('group', { name, exact: true })
}

test.describe('a11y: Selects are named by their field label (#65)', () => {
  test('all three Selects expose their visible label as the accessible name', async ({ page }) => {
    // --- Register once, then build state through the API --------------------
    await page.goto('/register')
    await expect(page.getByRole('heading', { name: 'Create account' })).toBeVisible()

    const email = uniqueEmail('a11y')
    await page.getByRole('textbox', { name: 'Email', exact: true }).fill(email)
    await page.getByRole('textbox', { name: 'Password', exact: true }).fill(TEST_PASSWORD)
    await page.getByRole('textbox', { name: 'Confirm password', exact: true }).fill(TEST_PASSWORD)
    await page.getByRole('textbox', { name: 'Invite code', exact: true }).fill(INVITE_CODE)
    await page.getByRole('button', { name: 'Create account' }).click()

    await expect(page.getByRole('heading', { name: 'Portfolios', level: 1 })).toBeVisible()

    await primeCsrf(page)
    const portfolio = await createPortfolio(page, { name: 'A11y portfolio' })

    // --- 1. Benchmark (PortfolioFormDialog, pre-dates M7) -------------------
    await page.getByRole('button', { name: 'New portfolio' }).first().click()
    const dialog = page.getByRole('dialog')
    await expect(dialog).toBeVisible()

    const benchmark = comboboxNamed(dialog, BENCHMARK_LABEL)
    await expect(benchmark, 'Benchmark Select should be named by its label').toHaveCount(1)

    // The Select must still SELECT. This is the half of the fix a name-only
    // assertion cannot see: aria-labelledby is applied through the same
    // pass-through section that carries the combobox's classes, so a mistake
    // there could name the field correctly and break the control.
    await benchmark.click()
    const spy = page.getByRole('option', { name: /SPY/ }).first()
    await expect(spy).toBeVisible()
    await spy.click()

    // Selecting must NOT re-point the accessible name at the chosen value —
    // that is precisely the regression being fixed.
    await expect(
      comboboxNamed(dialog, BENCHMARK_LABEL),
      'the name must survive a selection',
    ).toHaveCount(1)
    await expect(benchmark).toContainText('SPY')

    // vee-validate/zod still governs the form: a blank name is rejected and the
    // dialog stays open rather than submitting.
    await dialog.getByRole('textbox', { name: 'Name', exact: true }).fill('')
    await dialog.getByRole('button', { name: 'Create portfolio' }).click()
    await expect(dialog.getByRole('alert').first()).toBeVisible()
    await expect(dialog).toBeVisible()

    await dialog.getByRole('textbox', { name: 'Name', exact: true }).fill('A11y second')
    await dialog.getByRole('button', { name: 'Create portfolio' }).click()
    await expect(page.getByRole('heading', { name: 'A11y second' })).toBeVisible()

    // --- 2. Kind (TransactionFormDrawer) ------------------------------------
    await page.goto(`/portfolios/${portfolio.id}/transactions`)
    await expect(page.getByRole('heading', { name: 'Transactions', level: 1 })).toBeVisible()

    await page.getByRole('button', { name: 'Add transaction' }).first().click()
    const drawer = page.getByRole('dialog')
    await expect(drawer).toBeVisible()

    const kind = comboboxNamed(drawer, KIND_LABEL)
    await expect(kind, 'Kind Select should be named by its label').toHaveCount(1)

    // Its default value is "Normal" — the string that used to BE the accessible
    // name. Assert it is now only the value, never the name.
    await expect(kind).toContainText('Normal')
    await expect(
      comboboxNamed(drawer, 'Normal'),
      'the selected value must not masquerade as the accessible name',
    ).toHaveCount(0)

    await kind.click()
    const drip = page.getByRole('option', { name: 'Dividend reinvestment' })
    await expect(drip).toBeVisible()
    await drip.click()
    await expect(kind).toContainText('Dividend reinvestment')
    await expect(comboboxNamed(drawer, KIND_LABEL)).toHaveCount(1)

    // --- 3a. Side, a SelectButton (#69) -------------------------------------
    // SelectButton declares no `inputId` prop, so `:input-id="id"` fell through
    // as a plain attribute onto its `<div role="group">` and FormField's
    // `<label for>` pointed at an id that existed nowhere in the document.
    // Measured before the fix: 0.
    const side = groupNamed(drawer, SIDE_LABEL)
    await expect(side, 'the Side SelectButton should be named by its label').toHaveCount(1)

    // The same call site's `input-id` must not survive as an invalid DOM
    // attribute on that div — the second half of #69.
    await expect(side).not.toHaveAttribute('input-id')

    // It must still SELECT. `Sell` and `Buy` are ToggleButtons inside the group.
    await drawer.getByRole('button', { name: 'Sell', exact: true }).click()
    await expect(drawer.getByRole('button', { name: 'Sell', exact: true })).toHaveAttribute(
      'aria-pressed',
      'true',
    )
    await expect(groupNamed(drawer, SIDE_LABEL), 'the name must survive a selection').toHaveCount(1)

    // --- 3b. Ticker, an AutoComplete (#70) ----------------------------------
    // `aria-describedby` was swept into the root `ptmi()` and landed on the
    // outer wrapper `<div>`, never on the inner `<input role="combobox">`, so
    // the computed accessible description was "" — hint AND error unannounced.
    const ticker = comboboxNamed(drawer, 'Ticker')
    await expect(ticker, 'Ticker is a real <input>, so its NAME was never broken').toHaveCount(1)
    await expect(ticker, 'the hint must be announced, not merely displayed').toHaveAccessibleDescription(
      TICKER_HINT,
    )

    // Force a validation error, and assert the ERROR is what gets announced.
    // FormField swaps hint for error, so this also proves the description
    // tracks state rather than being wired once at mount.
    // NB: scoped to the drawer — the page behind it has an "Add transaction"
    // button too (the one that opened this drawer).
    await drawer.getByRole('button', { name: 'Add transaction', exact: true }).click()
    await expect(drawer.getByText(TICKER_ERROR)).toBeVisible()
    await expect(ticker).toHaveAccessibleDescription(TICKER_ERROR)
    await expect(ticker).toHaveAttribute('aria-invalid', 'true')

    // `smoke.spec.js` addresses Ticker and Date by accessible name and was
    // tightened to `exact: true` in the same pass (#70 flagged both as the same
    // shape as the trap that nearly shipped a vacuous assertion in #65). Pin
    // that the exact form still resolves, so the tightening cannot have quietly
    // made those two lookups match nothing.
    await expect(comboboxNamed(drawer, 'Date')).toHaveCount(1)

    // --- 3. Frequency (RecurringFormDrawer) ---------------------------------
    await page.goto(`/portfolios/${portfolio.id}/recurring`)
    await expect(page.getByRole('heading', { name: 'Recurring buys', level: 1 })).toBeVisible()

    await page.getByRole('button', { name: 'New recurring buy' }).first().click()
    const recurringDrawer = page.getByRole('dialog')
    await expect(recurringDrawer).toBeVisible()

    const frequency = comboboxNamed(recurringDrawer, FREQUENCY_LABEL)
    await expect(frequency, 'Frequency Select should be named by its label').toHaveCount(1)

    await frequency.click()
    const quarterly = page.getByRole('option', { name: 'Quarterly' })
    await expect(quarterly).toBeVisible()
    await quarterly.click()
    await expect(frequency).toContainText('Quarterly')
    await expect(comboboxNamed(recurringDrawer, FREQUENCY_LABEL)).toHaveCount(1)

    // --- 5. Invest by, the second SelectButton (#69) -------------------------
    const investBy = groupNamed(recurringDrawer, INVEST_BY_LABEL)
    await expect(investBy, 'the Invest by SelectButton should be named by its label').toHaveCount(1)
    await expect(investBy).not.toHaveAttribute('input-id')
  })
})
