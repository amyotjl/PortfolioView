import { expect, test } from '@playwright/test'
import { INVITE_CODE, TEST_PASSWORD, uniqueEmail } from './helpers/api.js'

/**
 * Issue #73 — a second user signing in to the same tab must never see the first
 * user's data.
 *
 * WHY THIS CANNOT BE A VITEST TEST. The defect is a property of SPA navigation:
 * the Pinia Colada caches outlive component teardown, no cache key carries a
 * user id, and A FULL PAGE RELOAD MASKS THE WHOLE THING. A unit test can (and
 * does — `frontend/src/stores/auth.spec.ts`) prove that a fresh mount after
 * `clear()` renders no rows, but only a browser proves that the real
 * register → sign out → register path never reloads, and therefore really is
 * the reported reproduction.
 *
 * SO: THERE IS EXACTLY ONE `page.goto` IN THIS SPEC, at the very start. Every
 * later navigation is a click, which the router handles in-page. A `page.goto`
 * or `page.reload()` added mid-spec would silently make it vacuous by reloading
 * away the caches under test — the thing that hid this bug for four milestones.
 * The `pageLoads` counter fails the test if that ever happens rather than
 * leaving it for a reviewer to spot.
 *
 * The portfolios are created THROUGH THE UI, not through the API helpers the
 * other specs use, and that is also load-bearing: an API-created portfolio is
 * never pulled into the query cache, so the spec would assert the absence of
 * something that was never cached and would pass against the unfixed code.
 *
 * Registration is rate-limited to 10 per 3 minutes and this spec needs TWO
 * accounts, so it spends 2 of that budget; a full suite run now spends 5.
 */

const A_PORTFOLIO = 'Alice private holdings'
const B_PORTFOLIO = 'Bob private holdings'

/** Fills and submits the register form on an already-open /register page. */
async function registerThrough(page, email) {
  await expect(page.getByRole('heading', { name: 'Create account' })).toBeVisible()
  await page.getByRole('textbox', { name: 'Email', exact: true }).fill(email)
  await page.getByRole('textbox', { name: 'Password', exact: true }).fill(TEST_PASSWORD)
  await page.getByRole('textbox', { name: 'Confirm password', exact: true }).fill(TEST_PASSWORD)
  await page.getByRole('textbox', { name: 'Invite code', exact: true }).fill(INVITE_CODE)
  await page.getByRole('button', { name: 'Create account' }).click()
  await expect(page.getByRole('heading', { name: 'Portfolios', level: 1 })).toBeVisible()
}

/**
 * Creates a portfolio through the New-portfolio dialog, so the create mutation
 * invalidates `['portfolios']` and the resulting card is genuinely cached.
 */
async function createPortfolioThroughUi(page, name) {
  await page.getByRole('button', { name: 'New portfolio' }).first().click()
  const dialog = page.getByRole('dialog')
  await expect(dialog).toBeVisible()
  await dialog.getByRole('textbox', { name: 'Name', exact: true }).fill(name)
  await dialog.getByRole('button', { name: 'Create portfolio' }).click()
  await expect(page.getByRole('heading', { name })).toBeVisible()
}

test.describe('session isolation in one tab (#73)', () => {
  test('signing out drops the previous user’s cached data', async ({ page }) => {
    // Any full document load resets the caches, which would make every
    // assertion below vacuous. Count them, and assert the count at the end.
    let pageLoads = 0
    page.on('load', () => {
      pageLoads += 1
    })

    // --- User A: register, own a portfolio, and RENDER it -------------------
    await page.goto('/register')
    await registerThrough(page, uniqueEmail('iso-a'))
    await createPortfolioThroughUi(page, A_PORTFOLIO)

    // --- A signs out. SPA navigation only — no reload. ----------------------
    await page.getByRole('button', { name: 'Sign out' }).click()
    await expect(page.getByRole('heading', { name: 'Sign in' })).toBeVisible()

    // --- User B: register from the login page's own link --------------------
    await page.getByRole('link', { name: 'Register' }).click()
    await registerThrough(page, uniqueEmail('iso-b'))

    // THE ASSERTION. B is on the portfolios page, in the same document A used.
    // Before the fix A's card rendered here immediately and stayed (measured on
    // a production stack during #58: A-portfolio=1 at once, still 1 after 3s).
    await expect(
      page.getByRole('heading', { name: A_PORTFOLIO }),
      "B must never see A's portfolio",
    ).toHaveCount(0)

    // B's own view still works — the fix must empty the cache, not break it.
    await createPortfolioThroughUi(page, B_PORTFOLIO)
    await expect(page.getByRole('heading', { name: A_PORTFOLIO })).toHaveCount(0)

    // The empty state and B's single card are mutually exclusive; asserting the
    // count pins that B sees exactly their own data, not "nothing at all".
    await expect(page.getByRole('heading', { name: B_PORTFOLIO })).toHaveCount(1)

    expect(pageLoads, 'a mid-spec reload would make this spec vacuous').toBe(1)
  })
})
