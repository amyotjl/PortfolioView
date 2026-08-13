/**
 * Captures the README media from the demo account (`bin/rails demo:seed`).
 *
 * A standalone script rather than a *.spec.js on purpose: the default testMatch
 * is `**\/*.spec.js`, so a spec here would join the real e2e suite, depend on
 * seeded demo data the suite must not require, and spend suite runtime writing
 * marketing assets.
 *
 *   docker compose --profile e2e run --rm e2e \
 *     bash -c "npm install --no-audit --no-fund && node capture-readme.mjs"
 *
 * Four things here were learned the hard way and should not be "simplified":
 *
 *  - THE THEME IS SET VIA localStorage BEFORE FIRST PAINT (`addInitScript`),
 *    never by clicking the toggle. index.html's pre-mount script reads `pv-theme`,
 *    so the first frame is already dark. A post-load toggle animates ~400ms of
 *    `transition-colors`, and a screenshot during it captures a half-applied
 *    palette that looks exactly like a theming bug (docs/STATUS.md).
 *
 *  - `fullPage: true` IS USELESS IN THIS APP. AppShell scrolls an inner
 *    `<main class="overflow-y-auto">`, not the document, so the "full page" is
 *    exactly the viewport. Long shots therefore RESIZE THE VIEWPORT to the
 *    measured content height instead.
 *
 *  - The dashboard's state lives in `?range=…&benchmark=true` (useDashboardParams),
 *    and the range presets are UPPERCASE (`5Y`, `ALL` — see RANGE_PRESETS). Any
 *    other spelling is dropped in silence: `benchmark=1` leaves the comparison OFF
 *    and `range=5y` falls back to the store's default 1Y. Both failure modes look
 *    like a correct screenshot of a different view, so check the range buttons and
 *    the legend in the output.
 *
 *  - ECharts animates on mount, so each shot waits for its canvas and then a
 *    settle delay; `reducedMotion` does not reach a canvas renderer.
 */
import { chromium } from '@playwright/test'
import { mkdir, readdir, unlink } from 'node:fs/promises'

const BASE_URL = process.env.E2E_BASE_URL ?? 'http://vite:5173'
const EMAIL = process.env.DEMO_EMAIL ?? 'demo@portfolioview.app'
const PASSWORD = process.env.DEMO_PASSWORD ?? 'demo-portfolio-2026'
const OUT = process.env.CAPTURE_OUT ?? 'capture-out'

/** Logical viewport; deviceScaleFactor 2 makes every PNG 2x for HiDPI READMEs. */
const WIDTH = 1440
const HEIGHT = 900
const SCALE = 2

const SETTLE = 900

async function settle(page, ms = SETTLE) {
  await page.waitForLoadState('networkidle').catch(() => {})
  await page.waitForTimeout(ms)
}

async function shot(page, name, options = {}) {
  await page.screenshot({ path: `${OUT}/${name}.png`, animations: 'disabled', ...options })
  console.log(`  → ${name}.png`)
}

/**
 * The card that owns a heading: its NEAREST ancestor <section>. Cards nest —
 * AllocationSection is a <section> wrapping two ChartCard <section>s — so
 * `locator('section').filter({has: heading})` matches both and `.first()` grabs
 * the outer one. Walking up from the heading is unambiguous.
 */
function card(page, heading) {
  return page
    .getByRole('heading', { name: heading, exact: true })
    .locator('xpath=ancestor::section[1]')
}

/**
 * Element shot, with the viewport GROWN to fit the element first.
 *
 * `locator.screenshot()` alone is not enough here: for an element taller than the
 * viewport Playwright scrolls-and-stitches, and against an inner scroll container
 * that stitching produces a correct top strip followed by a black void (and, for a
 * long table, a second copy of the header). Resizing first means the whole element
 * is on screen for a single frame, which is also what re-lays-out the charts at
 * their final size.
 *
 * `crop` limits how much of a long element is kept — a 3,000px cash ledger is a
 * complete record and a terrible screenshot.
 */
async function shotOf(page, locator, name, { crop = null, max = 3200 } = {}) {
  await page.setViewportSize({ width: WIDTH, height: HEIGHT })

  // ALWAYS `block: 'start'`, never scrollIntoViewIfNeeded. For an element taller
  // than the viewport, "if needed" is satisfied by bringing its BOTTOM into view,
  // which leaves its top at a negative y — a crop then clamps to 0 and silently
  // captures the middle of the element plus whatever sticky chrome is overhead.
  // That produced a "Trades" shot with no table header and the top bar bleeding in.
  const toStart = () => locator.evaluate((el) => el.scrollIntoView({ block: 'start' }))
  await toStart()
  await settle(page, 300)

  let box = await locator.boundingBox()
  if (!box) throw new Error(`no bounding box for ${name}`)

  const fit = Math.min(max, Math.ceil(crop ? Math.min(box.height, crop) : box.height) + 160)
  if (fit > HEIGHT) {
    await page.setViewportSize({ width: WIDTH, height: fit })
    await toStart()
    await settle(page, 900)
    box = await locator.boundingBox()
  }

  if (crop) {
    const viewport = page.viewportSize()
    const y = Math.max(0, box.y)
    await shot(page, name, {
      clip: {
        x: Math.max(0, box.x),
        y,
        width: Math.min(box.width, viewport.width - Math.max(0, box.x)),
        height: Math.min(crop, box.height, viewport.height - y),
      },
    })
  } else {
    await locator.screenshot({ path: `${OUT}/${name}.png`, animations: 'disabled' })
    console.log(`  → ${name}.png`)
  }
  await page.setViewportSize({ width: WIDTH, height: HEIGHT })
}

/**
 * Viewport shot cropped to end just below `locator` — used for the hero, which
 * wants the stat tiles AND the whole chart card in one frame and nothing after
 * it. Resizing the viewport (rather than clipping) re-lays-out and re-renders the
 * charts at the taller size, so nothing is cut mid-canvas.
 */
async function shotThrough(page, locator, name, tail = 20) {
  await page.setViewportSize({ width: WIDTH, height: HEIGHT })
  await page.evaluate(() => document.querySelector('main')?.scrollTo(0, 0))
  const box = await locator.boundingBox()
  if (!box) throw new Error(`no bounding box for ${name}`)
  const height = Math.min(4000, Math.ceil(box.y + box.height + tail))
  await page.setViewportSize({ width: WIDTH, height })
  await settle(page, 1200)
  await shot(page, name)
  await page.setViewportSize({ width: WIDTH, height: HEIGHT })
}

/**
 * Whole-page shot: grow the viewport to the inner scroll height, then trim the
 * empty tail. A page with three portfolio cards leaves ~600px of background under
 * them, which reads as a rendering failure in a README rather than as an empty
 * state, so `floor` keeps a sensible minimum and the content bound wins otherwise.
 */
async function shotWholePage(page, name, { max = 2600, floor = 520 } = {}) {
  await page.setViewportSize({ width: WIDTH, height: HEIGHT })
  // Back to the top: a preceding element shot leaves the inner scroller wherever
  // it was, and a capped page shot would then start mid-table with no header.
  await page.evaluate(() => document.querySelector('main')?.scrollTo(0, 0))
  await settle(page, 300)
  const needed = await page.evaluate(() => {
    const main = document.querySelector('main')
    if (!main) return document.body.scrollHeight
    const chrome = window.innerHeight - main.clientHeight
    // The bottom of the last INK, found from leaf elements. Neither scrollHeight
    // nor the direct children work: the layout wrapper is a flex child that
    // stretches to the full height, so both report "content ends at the bottom of
    // the viewport" for a page holding two cards, and the shot comes out mostly
    // empty background.
    const top = main.getBoundingClientRect().top
    const leaves = [...main.querySelectorAll('*')].filter((el) => {
      if (el.children.length > 0) return false
      const rect = el.getBoundingClientRect()
      return rect.height > 0 && rect.width > 0
    })
    if (!leaves.length) return main.scrollHeight + chrome
    const ink = Math.max(...leaves.map((el) => el.getBoundingClientRect().bottom - top))
    return Math.min(main.scrollHeight, Math.ceil(ink) + 24) + chrome
  })
  await page.setViewportSize({ width: WIDTH, height: Math.min(max, Math.max(floor, Math.ceil(needed))) })
  await settle(page, 900)
  await shot(page, name)
  await page.setViewportSize({ width: WIDTH, height: HEIGHT })
}

async function signIn(page) {
  await page.goto(`${BASE_URL}/login`)
  await page.getByRole('textbox', { name: 'Email', exact: true }).fill(EMAIL)
  await page.getByRole('textbox', { name: 'Password', exact: true }).fill(PASSWORD)
  await page.getByRole('button', { name: 'Sign in' }).click()
  await page.getByRole('heading', { name: 'Portfolios', level: 1 }).waitFor()
}

async function demoPortfolios(page) {
  const response = await page.request.get(`${BASE_URL}/api/v1/portfolios`)
  if (!response.ok()) throw new Error(`GET /portfolios failed: ${response.status()}`)
  const { portfolios } = await response.json()
  const byName = Object.fromEntries(portfolios.map((p) => [p.name, p.id]))
  if (!byName['Core Growth']) {
    throw new Error(
      `demo data missing — run "bin/rails demo:seed" (have: ${Object.keys(byName).join(', ') || 'none'})`,
    )
  }
  return byName
}

async function openDashboard(page, id, { range = '5Y', benchmark = true } = {}) {
  const query = `range=${range}${benchmark ? '&benchmark=true' : ''}`
  await page.goto(`${BASE_URL}/portfolios/${id}?${query}`)
  await page.locator('canvas').first().waitFor()
  await settle(page, 1600)
}

/**
 * Empty the output directory OF THIS SCRIPT'S OWN ARTIFACTS, file by file.
 *
 * Two constraints, both learned by breaking them:
 *  - `rm(dir, {recursive:true})` fails with EACCES on rmdir against the Windows
 *    A:-drive bind mount even though writing and unlinking inside it work, so
 *    removing the directory is the one operation to avoid here.
 *  - It must not touch `tour.*`. Those belong to capture-tour.mjs, take minutes
 *    to rebuild, and a sweep of every image extension quietly deleted the GIF
 *    between the two scripts.
 */
async function clearOutput() {
  await mkdir(OUT, { recursive: true })
  for (const entry of await readdir(OUT)) {
    if (entry.endsWith('.png') && !entry.startsWith('tour')) await unlink(`${OUT}/${entry}`)
  }
}

async function main() {
  await clearOutput()

  const browser = await chromium.launch()
  const context = await browser.newContext({
    viewport: { width: WIDTH, height: HEIGHT },
    deviceScaleFactor: SCALE,
    colorScheme: 'dark',
    reducedMotion: 'reduce',
  })
  await context.addInitScript(() => window.localStorage.setItem('pv-theme', 'dark'))

  const page = await context.newPage()
  const serverErrors = []
  page.on('response', (r) => {
    if (r.url().includes('/api/v1/') && r.status() >= 500) {
      serverErrors.push(`${r.status()} ${r.request().method()} ${r.url()}`)
    }
  })

  console.log(`signing in as ${EMAIL}`)
  await signIn(page)
  const ids = await demoPortfolios(page)
  const growth = ids['Core Growth']

  // --- Portfolios overview (cards, sparklines, totals) ---------------------
  await page.goto(`${BASE_URL}/portfolios`)
  await settle(page, 1200)
  await shotWholePage(page, 'portfolios', { max: 1200 })

  // --- Dashboard ------------------------------------------------------------
  await openDashboard(page, growth, { range: 'ALL', benchmark: true })

  // Hero: stat tiles through the end of the value/flow/drawdown chart.
  await shotThrough(page, card(page, 'Value, cash flow & drawdown'), 'dashboard')

  await shotOf(page, card(page, 'Value, cash flow & drawdown'), 'chart-value')
  await shotOf(page, card(page, 'Contributed capital vs growth'), 'chart-contribution')
  await shotOf(page, card(page, 'Allocation'), 'allocation')
  await shotOf(page, card(page, 'Sector breakdown'), 'treemap')

  // A short range as well: over 3.5 years the candle bodies compress into a line,
  // so the one chart type the app is named for is best shown at 6M.
  await openDashboard(page, growth, { range: '6M', benchmark: true })
  await shotOf(page, card(page, 'Value, cash flow & drawdown'), 'chart-value-6m')

  // The same chart as a table — the accessible twin every card carries.
  const valueCard = card(page, 'Value, cash flow & drawdown')
  await valueCard.getByRole('button', { name: 'Table' }).click()
  await settle(page, 500)
  await shotOf(page, valueCard, 'chart-value-table', { crop: 620 })
  await valueCard.getByRole('button', { name: 'Chart' }).click()

  // --- Transactions (which also owns the Cash ledger) and recurring --------
  await page.goto(`${BASE_URL}/portfolios/${growth}/transactions`)
  await settle(page, 1000)
  await shotOf(page, card(page, 'Cash'), 'cash', { crop: 620 })
  await shotOf(page, card(page, 'Trades'), 'trades', { crop: 680 })
  await shotWholePage(page, 'transactions', { max: 1500 })

  await page.goto(`${BASE_URL}/portfolios/${growth}/recurring`)
  await settle(page, 1000)
  await shotWholePage(page, 'recurring', { max: 1200 })

  // --- The Canadian book, for the multi-currency story ----------------------
  if (ids['TFSA — Canadian Core']) {
    await openDashboard(page, ids['TFSA — Canadian Core'], { range: 'ALL', benchmark: false })
    await shotThrough(page, card(page, 'Value, cash flow & drawdown'), 'dashboard-cad')
  }

  await browser.close()

  if (serverErrors.length) {
    console.error(`5xx during capture:\n${serverErrors.join('\n')}`)
    process.exitCode = 1
  }
}

await main()
