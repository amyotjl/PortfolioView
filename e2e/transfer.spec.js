import { expect, test } from '@playwright/test'
import { INVITE_CODE, TEST_PASSWORD, createTransaction, uniqueEmail } from './helpers/api.js'

/**
 * Portfolio export / import end to end (issue #64).
 *
 * Why this needs to be an e2e test and not a unit test: the two things most likely
 * to break here are invisible to Vitest and to the Rails suite.
 *   1. The export is a BLOB DOWNLOAD driven by a synthetic anchor click. Only a
 *      real browser fires the download event, honors the `download` attribute, and
 *      proves the object-URL dance actually saves a file.
 *   2. The import is a MULTIPART UPLOAD that must carry the session cookie and the
 *      X-XSRF-TOKEN header. Get the Content-Type handling wrong and Rack silently
 *      parses no file at all — a 422 that no fixture-based test would catch.
 *
 * It also closes the loop the feature exists for: a file exported from one account
 * is re-imported and the data comes back.
 *
 * Registration is rate-limited to 10 per 3 minutes; this file registers EXACTLY ONE
 * user and builds everything else through the API.
 */

/** Mirrors the Wealthsimple holdings-report shape, incl. a CAD/TSX CDR. */
const HOLDINGS_CSV = [
  'Account Name,Account Type,Account Classification,Account Number,Symbol,Exchange,MIC,Name,Security Type,Quantity,Position Direction,Market Price,Market Price Currency,Book Value (CAD),Book Value Currency (CAD),Book Value (Market),Book Value Currency (Market),Market Value,Market Value Currency,Market Unrealized Returns,Market Unrealized Returns Currency',
  '"E2E TFSA","TFSA","Trade","X1CAD","ZEQT","TSX","XTSE","BMO All-Equity ETF","EXCHANGE_TRADED_FUND","100","LONG","22.94","CAD","2210.035","CAD","2210.035","CAD","2294","CAD","83.965","CAD"',
  '"E2E TFSA","TFSA","Trade","X1CAD","META","TSX","XTSE","Meta CDR (CAD Hedged)","EQUITY","25","LONG","31.75","CAD","806.25","CAD","806.25","CAD","793.75","CAD","-12.5","CAD"',
  '',
  '"As of 2026-03-04 10:23 GMT-04:00"',
  '',
].join('\n')

/**
 * Screenshots are OPT-IN (`E2E_SCREENSHOTS=1`). They exist for the "render it and
 * look at it" check that docs/STATUS.md requires for new UI — which has caught
 * four defects in M8 that no assertion did — but a normal run must leave nothing
 * behind. Do NOT write them to playwright-report/: the HTML reporter wipes that
 * folder when the run ends.
 */
const SHOOT = Boolean(process.env.E2E_SCREENSHOTS)

async function shoot(page, name) {
  if (!SHOOT) return
  await page.screenshot({ path: `screenshots/${name}.png`, fullPage: true })
}

test.describe('export / import portfolios', () => {
  test('exports a file, previews it, imports it, and imports a broker CSV', async ({ page }) => {
    const apiFailures = []
    page.on('response', (response) => {
      const url = response.url()
      if (!url.includes('/api/v1/')) return
      // The 401 on the signed-out /session probe is expected. So is a 422 — the
      // import dialog deliberately shows server validation errors — so only 5xx
      // counts as a hard failure here.
      if (response.status() >= 500) {
        apiFailures.push(`${response.status()} ${response.request().method()} ${url}`)
      }
    })

    // --- Register and seed one portfolio with a transaction -----------------
    await page.goto('/register')
    const email = uniqueEmail('transfer')
    await page.getByRole('textbox', { name: 'Email', exact: true }).fill(email)
    await page.getByRole('textbox', { name: 'Password', exact: true }).fill(TEST_PASSWORD)
    await page.getByRole('textbox', { name: 'Confirm password', exact: true }).fill(TEST_PASSWORD)
    await page.getByRole('textbox', { name: 'Invite code', exact: true }).fill(INVITE_CODE)
    await page.getByRole('button', { name: 'Create account' }).click()
    await expect(page.getByRole('heading', { name: 'Portfolios', level: 1 })).toBeVisible()

    const created = await page.request.post('/api/v1/portfolios', {
      data: { name: 'Transfer Source', benchmark_id: null },
      headers: await csrfHeaders(page),
    })
    expect(created.ok(), await created.text()).toBe(true)
    const portfolio = (await created.json()).portfolio
    await createTransaction(page, portfolio.id, {
      symbol: 'AAPL',
      side: 'buy',
      shares: '4',
      price: '150.25',
      executed_on: '2026-01-05',
    })

    await page.reload()
    await expect(page.getByRole('heading', { name: 'Transfer Source' })).toBeVisible()

    // --- 1. Export downloads a real file ------------------------------------
    const [download] = await Promise.all([
      page.waitForEvent('download'),
      page.getByRole('button', { name: 'Export' }).click(),
    ])

    expect(download.suggestedFilename()).toMatch(/^portfolioview-portfolios-\d{8}-\d{6}\.json$/)

    const stream = await download.createReadStream()
    const chunks = []
    for await (const chunk of stream) chunks.push(chunk)
    const exported = Buffer.concat(chunks).toString('utf8')

    const envelope = JSON.parse(exported)
    expect(envelope.format).toBe('portfolioview.portfolios')
    expect(envelope.version).toBe(1)
    expect(envelope.portfolios.map((p) => p.name)).toContain('Transfer Source')
    expect(envelope.instruments.map((i) => i.symbol)).toContain('AAPL')
    // Money stays a string end to end.
    expect(typeof envelope.portfolios[0].transactions[0].price).toBe('string')

    // --- 2. Preview the same file: reports a rename, saves nothing ----------
    await page.getByRole('button', { name: 'Import' }).first().click()
    // Addressed by the dialog's ACCESSIBLE NAME, not a heading: PrimeVue's
    // unstyled Dialog renders its title as a plain <span>, so `role="heading"`
    // matches nothing (verified against the rendered aria tree).
    const dialog = page.getByRole('dialog', { name: 'Import portfolios' })
    await expect(dialog).toBeVisible()

    await dialog.getByLabel('File').setInputFiles({
      name: download.suggestedFilename(),
      mimeType: 'application/json',
      buffer: Buffer.from(exported, 'utf8'),
    })

    await dialog.getByRole('button', { name: 'Preview' }).click()
    await expect(dialog.getByText(/preview only, nothing was saved/i)).toBeVisible()
    await expect(dialog.getByText(/would import 1 portfolio/i)).toBeVisible()
    // The name already exists, so the preview must show the rename it would apply
    // — on the row itself, not only buried in the notes list.
    await expect(dialog.getByText('imported as “Transfer Source (imported)”')).toBeVisible()
    await expect(dialog.getByText('Renamed')).toBeVisible()
    // A preview must never claim the write already happened (regression: the
    // rename note used to read "was imported as").
    await expect(dialog.getByText(/was imported as/i)).toHaveCount(0)

    await shoot(page, 'import-preview-light')

    // Nothing may have been written by a preview.
    const afterPreview = await (await page.request.get('/api/v1/portfolios')).json()
    expect(afterPreview.portfolios.map((p) => p.name).sort()).toEqual(['Transfer Source'])

    // --- 3. Commit the import ----------------------------------------------
    await dialog.getByRole('button', { name: 'Import', exact: true }).click()
    await expect(dialog.getByText(/^Imported 1 portfolio with 1 transaction\./)).toBeVisible()
    // Committed runs collapse the form and offer only Done.
    await expect(dialog.getByRole('button', { name: 'Done' })).toBeVisible()
    await expect(dialog.getByLabel('File')).toBeHidden()

    await shoot(page, 'import-done-light')
    await dialog.getByRole('button', { name: 'Done' }).click()

    // The list refetched because the mutation invalidated the portfolios key.
    await expect(page.getByRole('heading', { name: 'Transfer Source (imported)' })).toBeVisible()

    // --- 4. Import a broker holdings CSV, warnings and all -----------------
    await page.getByRole('button', { name: 'Import' }).first().click()
    await dialog.getByLabel('File').setInputFiles({
      name: 'holdings-report.csv',
      mimeType: 'text/csv',
      buffer: Buffer.from(HOLDINGS_CSV, 'utf8'),
    })
    await dialog.getByRole('button', { name: 'Import', exact: true }).click()

    await expect(dialog.getByText(/Detected format: Broker holdings report/)).toBeVisible()
    await expect(dialog.getByText(/^Imported 1 portfolio with 2 transactions\./)).toBeVisible()
    // The caveats are the whole point of importing a snapshot — they must be on screen.
    await expect(dialog.getByText(/no trade history/i)).toBeVisible()
    await expect(dialog.getByText(/META → META\.TO/)).toBeVisible()
    await expect(dialog.getByText(/Price history is unavailable/i)).toBeVisible()

    await shoot(page, 'import-csv-light')

    // Dark theme: the report panel carries its own borders/fills, so it needs a look.
    //
    // The attribute is poked directly rather than clicking the top-bar toggle
    // because the modal mask correctly blocks clicks outside the dialog. And the
    // settle wait is REQUIRED, not padding: almost every control carries
    // `transition-colors`, so screenshotting immediately captures a half-applied
    // palette that looks exactly like a theming bug (it cost a debugging round).
    await page.evaluate(() => document.documentElement.setAttribute('data-theme', 'dark'))
    await page.waitForTimeout(400)
    await shoot(page, 'import-csv-dark')
    await page.evaluate(() => document.documentElement.setAttribute('data-theme', 'light'))
    await page.waitForTimeout(400)

    await dialog.getByRole('button', { name: 'Done' }).click()
    await expect(page.getByRole('heading', { name: 'E2E TFSA' })).toBeVisible()

    // --- 5. An unreadable file is a field error, not a crash ---------------
    await page.getByRole('button', { name: 'Import' }).first().click()
    await dialog.getByLabel('File').setInputFiles({
      name: 'nonsense.csv',
      mimeType: 'text/csv',
      buffer: Buffer.from('a,b,c\n1,2,3\n', 'utf8'),
    })
    await dialog.getByRole('button', { name: 'Import', exact: true }).click()
    // Prefixed with the field name: the server sends a Rails field FRAGMENT
    // ("must be a …"), which reads as a broken sentence on its own in a banner.
    await expect(dialog.getByRole('alert')).toContainText(/^File must be a PortfolioView JSON export/)

    await shoot(page, 'import-error-light')
    await dialog.getByRole('button', { name: 'Cancel' }).click()

    expect(apiFailures, 'no 5xx may occur anywhere in this flow').toEqual([])
  })
})

async function csrfHeaders(page) {
  const cookies = await page.context().cookies()
  const token = cookies.find((cookie) => cookie.name === 'XSRF-TOKEN')
  return {
    'Content-Type': 'application/json',
    ...(token ? { 'X-XSRF-TOKEN': decodeURIComponent(token.value) } : {}),
  }
}
