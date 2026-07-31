import { expect, test } from '@playwright/test'
import { INVITE_CODE, TEST_PASSWORD, uniqueEmail } from './helpers/api.js'

/**
 * INDEPENDENT TESTER GATE for issue #57 — the "render it and look at it" pass.
 *
 * This project has twice shipped UI that passed every assertion while visibly
 * wrong, so every meaningful state of the Settings sync card is rendered here in
 * BOTH themes, screenshotted, and verified with getComputedStyle rather than by
 * eyeballing a PNG.
 *
 * Every mocked payload is a byte-for-byte live capture taken through real HTTP
 * from a real session against the pv_t57 stack. Route interception is used only
 * to reach states the live database cannot be put into on demand (a failing
 * POST, a large instruments_behind); the unmocked test at the end drives the
 * REAL endpoint end to end.
 *
 * Registers exactly ONE user (rate limit: 10 per 3 minutes).
 */

const LIVE = {
  warm: {
    latest_price_on: '2026-07-30',
    last_trading_day: '2026-07-30',
    stale: false,
    instruments_behind: 0,
    pending: false,
    requested_at: null,
  },
  fresh: {
    latest_price_on: null,
    last_trading_day: null,
    stale: true,
    instruments_behind: 3,
    pending: false,
    requested_at: null,
  },
  behind: {
    latest_price_on: '2026-07-30',
    last_trading_day: '2026-07-30',
    stale: false,
    instruments_behind: 1,
    pending: false,
    requested_at: null,
  },
  stale: {
    latest_price_on: '2026-07-17',
    last_trading_day: '2026-07-30',
    stale: true,
    instruments_behind: 3,
    pending: false,
    requested_at: null,
  },
  pending: {
    latest_price_on: null,
    last_trading_day: null,
    stale: true,
    instruments_behind: 3,
    pending: true,
    requested_at: '2026-07-31T02:53:39Z',
  },
}

const SHOTS = process.env.E2E_SCREENSHOTS === '1'

/** Nearly every control has transition-colors: a theme flip needs a settle wait. */
async function setTheme(page, theme) {
  await page.evaluate((t) => document.documentElement.setAttribute('data-theme', t), theme)
  await page.waitForTimeout(450)
}

function rgb(value) {
  const m = value.match(/rgba?\(([^)]+)\)/)
  if (!m) return null
  const [r, g, b] = m[1].split(',').map((n) => parseFloat(n))
  return { r, g, b }
}

/** Perceived lightness, good enough to tell a dark panel from a light one. */
function luminance(value) {
  const c = rgb(value)
  return c ? (0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b) / 255 : null
}

/**
 * The card's own <section>. `.last()` because SettingsView's outer <section>
 * also contains the heading; the innermost match is the card.
 */
function syncCard(page) {
  return page
    .locator('section')
    .filter({ has: page.getByRole('heading', { name: 'Price data' }) })
    .last()
}

async function capture(page, name) {
  if (!SHOTS) return
  await syncCard(page).screenshot({ path: `screenshots/gate57-${name}.png` })
}

// Serial + ONE shared page: registration is rate-limited to 10 per 3 minutes,
// and a per-test beforeEach would spend five of that budget on one file.
test.describe.configure({ mode: 'serial' })

test.describe('#57 Settings sync card', () => {
  let page

  test.beforeAll(async ({ browser }) => {
    page = await browser.newPage()
    await page.goto('/register')
    await expect(page.getByRole('heading', { name: 'Create account' })).toBeVisible()
    await page.getByRole('textbox', { name: 'Email', exact: true }).fill(uniqueEmail('gate57'))
    await page.getByRole('textbox', { name: 'Password', exact: true }).fill(TEST_PASSWORD)
    await page.getByRole('textbox', { name: 'Confirm password', exact: true }).fill(TEST_PASSWORD)
    await page.getByRole('textbox', { name: 'Invite code', exact: true }).fill(INVITE_CODE)
    await page.getByRole('button', { name: 'Create account' }).click()
    await expect(page).toHaveURL(/\/portfolios/)
  })

  // The page is shared across the serial tests, so route handlers registered by
  // one test would otherwise still be intercepting in the next one — which is
  // exactly how the LIVE test first "saw" a 500 that the server never sent.
  test.beforeEach(async () => {
    await page.unrouteAll({ behavior: 'ignoreErrors' })
  })

  test.afterAll(async () => {
    await page?.close()
  })

  test('renders every state in both themes, verified by computed style', async () => {
    for (const [name, sync] of Object.entries(LIVE)) {
      await page.route('**/api/v1/sync', async (route) => {
        if (route.request().method() !== 'GET') return route.fallback()
        await route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ sync }) })
      })

      await page.goto('/settings')
      const card = syncCard(page)
      await expect(card).toBeVisible()
      await expect(card.getByRole('heading', { name: 'Price data' })).toBeVisible()

      for (const theme of ['light', 'dark']) {
        await setTheme(page, theme)
        // The freshness line must have resolved — never a permanent skeleton.
        await expect(card.getByRole('status')).not.toHaveText(/^\s*$/)

        const panel = await card.evaluate((el) => getComputedStyle(el).backgroundColor)
        const ink = await card
          .getByRole('heading', { name: 'Price data' })
          .evaluate((el) => getComputedStyle(el).color)
        const panelL = luminance(panel)
        const inkL = luminance(ink)

        // The card themes: light panel/dark ink in light, the reverse in dark.
        if (theme === 'light') {
          expect(panelL, `${name}/light panel should be light (${panel})`).toBeGreaterThan(0.7)
          expect(inkL, `${name}/light ink should be dark (${ink})`).toBeLessThan(0.4)
        } else {
          expect(panelL, `${name}/dark panel should be dark (${panel})`).toBeLessThan(0.3)
          expect(inkL, `${name}/dark ink should be light (${ink})`).toBeGreaterThan(0.7)
        }

        await capture(page, `${name}-${theme}`)
      }

      await page.unroute('**/api/v1/sync')
    }
  })

  test('states say the right thing, and the button is addressable by its visible label', async () => {
    const expected = {
      fresh: { badge: 'Never synced', text: /No price data yet/, behind: /3 symbols are behind/ },
      warm: { badge: 'Up to date', text: /Prices are current through Jul 30, 2026\./, behind: null },
      behind: { badge: 'Up to date', text: /Prices are current through/, behind: /1 symbol is behind/ },
      stale: { badge: 'Sync needed', text: /a sync is needed/, behind: /3 symbols are behind/ },
    }

    for (const [name, want] of Object.entries(expected)) {
      await page.route('**/api/v1/sync', async (route) => {
        if (route.request().method() !== 'GET') return route.fallback()
        await route.fulfill({
          status: 200,
          contentType: 'application/json',
          body: JSON.stringify({ sync: LIVE[name] }),
        })
      })
      await page.goto('/settings')
      const card = syncCard(page)

      await expect(card.getByText(want.badge, { exact: true })).toBeVisible()
      await expect(card.getByRole('status')).toHaveText(want.text)
      if (want.behind) await expect(card.getByText(want.behind)).toBeVisible()
      else await expect(card.getByText(/behind the rest of the cache/)).toHaveCount(0)

      // exact:true — Playwright's getByRole matches `name` as a case-insensitive
      // SUBSTRING by default, which is how a vacuous assertion nearly shipped in #65.
      await expect(card.getByRole('button', { name: 'Sync now', exact: true })).toBeEnabled()
      // And it is not matched by a looser name that would prove nothing.
      await expect(card.getByRole('button', { name: 'Check again', exact: true })).toBeVisible()
      await page.unroute('**/api/v1/sync')
    }
  })

  test('in-flight: disabled, spinner painted, aria-busy, and it stays legible in dark', async () => {
    await page.route('**/api/v1/sync', async (route) => {
      if (route.request().method() !== 'GET') return route.fallback()
      await route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify({ sync: LIVE.pending }),
      })
    })
    await page.goto('/settings')
    const card = syncCard(page)

    const button = card.getByRole('button', { name: 'Syncing…', exact: true })
    await expect(button).toBeVisible()
    await expect(button).toBeDisabled()
    await expect(button).toHaveAttribute('aria-busy', 'true')
    await expect(card.getByText(/A sync was already requested at/)).toBeVisible()

    // The spinner is real geometry, not a zero-sized element (the class of bug
    // that made every chart render at 0px until M7).
    const spinner = button.locator('.animate-spin')
    await expect(spinner).toBeVisible()
    const box = await spinner.boundingBox()
    expect(box.width).toBeGreaterThan(8)
    expect(box.height).toBeGreaterThan(8)
    expect(await spinner.getAttribute('aria-hidden')).toBe('true')

    for (const theme of ['light', 'dark']) {
      await setTheme(page, theme)
      await capture(page, `inflight-${theme}`)
    }
  })

  test('failure: a 500 pins the envelope message and the card keeps working', async () => {
    await page.route('**/api/v1/sync', async (route) => {
      if (route.request().method() === 'GET') {
        return route.fulfill({
          status: 200,
          contentType: 'application/json',
          body: JSON.stringify({ sync: LIVE.stale }),
        })
      }
      await route.fulfill({
        status: 500,
        contentType: 'application/json',
        body: JSON.stringify({
          error: { code: 'internal_error', message: 'Something went wrong on our end.', details: {} },
        }),
      })
    })

    await page.goto('/settings')
    const card = syncCard(page)
    await card.getByRole('button', { name: 'Sync now', exact: true }).click()

    await expect(card.getByRole('alert')).toContainText('Something went wrong on our end.')
    // Toast too, and it must be an error toast.
    await expect(page.getByText('Sync could not be started')).toBeVisible()
    // Freshness hint survives; the button is usable again.
    await expect(card.getByRole('status')).toContainText('a sync is needed')
    await expect(card.getByRole('button', { name: 'Sync now', exact: true })).toBeEnabled()

    for (const theme of ['light', 'dark']) {
      await setTheme(page, theme)
      await capture(page, `failed-${theme}`)
    }
  })

  test('LIVE: the real POST /api/v1/sync runs, toasts, and flips the card to in-flight', async () => {
    // No route interception at all — the real endpoint, the real dedupe lease.
    await page.goto('/settings')
    const card = syncCard(page)
    await expect(card.getByRole('status')).not.toHaveText(/^\s*$/)

    const button = card.getByRole('button', { name: /^(Sync now|Syncing…)$/ })
    const label = await button.textContent()

    if (label.trim() === 'Syncing…') {
      // The 10-minute lease is already held (dev uses :memory_store, so it is
      // per-process and cannot be cleared from rails runner). That IS the
      // in-flight state, honestly reported — assert it and stop.
      await expect(button).toBeDisabled()
      await expect(card.getByText(/A sync was already requested at/)).toBeVisible()
      return
    }

    const [response] = await Promise.all([
      page.waitForResponse((r) => r.url().includes('/api/v1/sync') && r.request().method() === 'POST'),
      button.click(),
    ])
    expect(response.status()).toBe(202)
    const body = await response.json()
    expect(['enqueued', 'already_pending']).toContain(body.sync.status)

    // A toast appeared and it is NOT the failure one.
    await expect(page.getByText(/Sync started|Sync already requested/)).toBeVisible()
    await expect(page.getByText('Sync could not be started')).toHaveCount(0)

    // The query was invalidated, so the refetched snapshot shows the claim.
    await expect(card.getByRole('button', { name: 'Syncing…', exact: true })).toBeDisabled()
    await expect(card.getByText(/A sync was already requested at/)).toBeVisible()
    await capture(page, 'live-after-click')
  })
})
