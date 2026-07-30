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
 * Registration is rate-limited to 10 per 3 minutes, so this file registers
 * EXACTLY ONE user and builds everything else through the API.
 */

/** The three Selects, by the visible label each must announce. */
const KIND_LABEL = 'Kind'
const FREQUENCY_LABEL = 'Frequency'
const BENCHMARK_LABEL = 'Benchmark'

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

    const benchmark = dialog.getByRole('combobox', { name: BENCHMARK_LABEL })
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
      dialog.getByRole('combobox', { name: BENCHMARK_LABEL }),
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

    const kind = drawer.getByRole('combobox', { name: KIND_LABEL })
    await expect(kind, 'Kind Select should be named by its label').toHaveCount(1)

    // Its default value is "Normal" — the string that used to BE the accessible
    // name. Assert it is now only the value, never the name.
    await expect(kind).toContainText('Normal')
    await expect(
      drawer.getByRole('combobox', { name: 'Normal' }),
      'the selected value must not masquerade as the accessible name',
    ).toHaveCount(0)

    await kind.click()
    const drip = page.getByRole('option', { name: 'Dividend reinvestment' })
    await expect(drip).toBeVisible()
    await drip.click()
    await expect(kind).toContainText('Dividend reinvestment')
    await expect(drawer.getByRole('combobox', { name: KIND_LABEL })).toHaveCount(1)

    // --- 3. Frequency (RecurringFormDrawer) ---------------------------------
    await page.goto(`/portfolios/${portfolio.id}/recurring`)
    await expect(page.getByRole('heading', { name: 'Recurring buys', level: 1 })).toBeVisible()

    await page.getByRole('button', { name: 'New recurring buy' }).first().click()
    const recurringDrawer = page.getByRole('dialog')
    await expect(recurringDrawer).toBeVisible()

    const frequency = recurringDrawer.getByRole('combobox', { name: FREQUENCY_LABEL })
    await expect(frequency, 'Frequency Select should be named by its label').toHaveCount(1)

    await frequency.click()
    const quarterly = page.getByRole('option', { name: 'Quarterly' })
    await expect(quarterly).toBeVisible()
    await quarterly.click()
    await expect(frequency).toContainText('Quarterly')
    await expect(recurringDrawer.getByRole('combobox', { name: FREQUENCY_LABEL })).toHaveCount(1)
  })
})
