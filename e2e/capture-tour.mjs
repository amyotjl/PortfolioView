/**
 * Records the README's animated tour from the demo account (`bin/rails demo:seed`)
 * and converts it to a GIF (plus an MP4 for anyone who wants the sharper copy).
 *
 *   docker compose --profile e2e run --rm e2e bash -c \
 *     "apt-get update -qq && apt-get install -y -qq ffmpeg && node capture-tour.mjs"
 *
 * ffmpeg IS NOT PRESENT in the playwright image, and the build it bundles under
 * `/ms-playwright/ffmpeg-NNNN/` CANNOT do this job: it exists for video capture
 * only — VP8 encode/decode plus the `scale` filter, with no GIF encoder, no `fps`
 * and no palettegen/paletteuse. Hence the apt-get above. Without ffmpeg this
 * script still records `tour.webm` and just skips the conversions.
 *
 * KEEP THE TOUR SHORT AND SMALL. A GIF is essentially a frame sequence, so its
 * size scales with duration × area × fps. Measured on this exact clip:
 *
 *   960px 10fps 128 colors -> 7.2 MB     840px 8fps 64 colors -> 3.8 MB
 *   900px  9fps  64 colors -> 5.1 MB     800px 8fps 48 colors -> 3.2 MB
 *
 * Hence 800px / 8fps / 48 colors over ~16s, which lands near 2.5MB — heavy enough
 * to look good, light enough that the README still loads. The MP4 is a fifth of
 * that, but GitHub only auto-plays videos it hosts as attachments, so the GIF is
 * what actually renders inline and the MP4 is the "sharper copy" link.
 */
import { chromium } from '@playwright/test'
import { mkdir, readdir, rename, unlink } from 'node:fs/promises'
import { existsSync } from 'node:fs'
import { execFile } from 'node:child_process'
import { promisify } from 'node:util'

const run = promisify(execFile)

const BASE_URL = process.env.E2E_BASE_URL ?? 'http://vite:5173'
const EMAIL = process.env.DEMO_EMAIL ?? 'demo@portfolioview.app'
const PASSWORD = process.env.DEMO_PASSWORD ?? 'demo-portfolio-2026'
const OUT = process.env.CAPTURE_OUT ?? 'capture-out'
const VIDEO_DIR = `${OUT}/video`

/** Recording size. 1280x800 downscales to an 800px GIF without looking soft. */
const SIZE = { width: 1280, height: 800 }
const GIF_WIDTH = 800
const GIF_FPS = 8
const GIF_COLORS = 48

/** Seconds trimmed off the head of the recording (the page's blank first frames). */
const HEAD_TRIM = 0.4

/** Beat between steps — long enough to read, short enough to keep the GIF small. */
const BEAT = 900

async function beat(page, ms = BEAT) {
  await page.waitForTimeout(ms)
}

/**
 * Sign in through the API on the CONTEXT, before any page exists.
 *
 * `context.request` shares the context's cookie jar, so the session it
 * establishes is the one the page will use. Doing it this way keeps ~3 seconds of
 * someone typing credentials out of a 17-second GIF — and recording is per page,
 * so there is no way to sign in on camera-off and then start rolling.
 */
async function signIn(context) {
  await context.request.get(`${BASE_URL}/api/v1/session`, { failOnStatusCode: false })
  const cookies = await context.cookies()
  const token = cookies.find((c) => c.name === 'XSRF-TOKEN')
  const response = await context.request.post(`${BASE_URL}/api/v1/session`, {
    data: { email_address: EMAIL, password: PASSWORD },
    headers: {
      'Content-Type': 'application/json',
      ...(token ? { 'X-XSRF-TOKEN': decodeURIComponent(token.value) } : {}),
    },
    failOnStatusCode: false,
  })
  if (!response.ok()) {
    throw new Error(`sign-in failed for ${EMAIL}: ${response.status()} ${await response.text()}`)
  }
}

/** Smooth programmatic scroll of AppShell's inner scroller (the page never scrolls). */
async function glideTo(page, y, ms = 900) {
  await page.evaluate(
    ([target, duration]) => {
      const main = document.querySelector('main')
      if (!main) return
      const start = main.scrollTop
      const distance = target - start
      const t0 = performance.now()
      return new Promise((resolve) => {
        const step = (now) => {
          const p = Math.min(1, (now - t0) / duration)
          // easeInOutQuad: a linear pan reads as a jump cut at 10fps.
          main.scrollTop = start + distance * (p < 0.5 ? 2 * p * p : 1 - (-2 * p + 2) ** 2 / 2)
          if (p < 1) requestAnimationFrame(step)
          else resolve()
        }
        requestAnimationFrame(step)
      })
    },
    [y, ms],
  )
}

/**
 * Drag the crosshair across the price pane so the shared tooltip animates. This
 * is the one thing a still screenshot cannot show — the linked panes reading a
 * single day — so it gets the longest beat in the tour.
 */
async function sweepTooltip(page) {
  const canvas = page.locator('canvas').first()
  const box = await canvas.boundingBox()
  if (!box) return
  const y = box.y + box.height * 0.3
  const from = box.x + box.width * 0.45
  const to = box.x + box.width * 0.9
  await page.mouse.move(from, y)
  await beat(page, 500)
  for (let i = 1; i <= 12; i += 1) {
    await page.mouse.move(from + ((to - from) * i) / 12, y + Math.sin(i / 2) * 12)
    await page.waitForTimeout(90)
  }
  await beat(page, 700)
  await page.mouse.move(box.x + box.width / 2, box.y - 60)
}

async function ffmpeg() {
  for (const candidate of ['ffmpeg', '/usr/bin/ffmpeg']) {
    try {
      await run(candidate, ['-version'])
      return candidate
    } catch {
      /* keep looking */
    }
  }
  return null
}

async function convert(webm) {
  const bin = await ffmpeg()
  if (!bin) {
    console.log('! ffmpeg not installed — keeping tour.webm only (see the header comment)')
    return
  }

  const palette = `${OUT}/palette.png`
  const filters = `fps=${GIF_FPS},scale=${GIF_WIDTH}:-1:flags=lanczos`
  // `-ss HEAD_TRIM` drops the blank first moments of the recording (see above).
  const head = ['-ss', String(HEAD_TRIM), '-i', webm]
  // Two passes: one global palette for the whole clip, then dithered mapping.
  // A single-pass GIF picks a palette per frame and the dark UI visibly shimmers.
  await run(bin, ['-y', ...head, '-vf', `${filters},palettegen=max_colors=${GIF_COLORS}`, palette])
  await run(bin, [
    '-y', ...head, '-i', palette,
    '-lavfi', `${filters}[x];[x][1:v]paletteuse=dither=bayer:bayer_scale=3`,
    `${OUT}/tour.gif`,
  ])
  await unlink(palette)
  await run(bin, [
    '-y', ...head,
    '-vf', `scale=${GIF_WIDTH}:-2`,
    '-c:v', 'libx264', '-preset', 'slow', '-crf', '26', '-pix_fmt', 'yuv420p',
    '-movflags', '+faststart',
    `${OUT}/tour.mp4`,
  ])
  console.log('  → tour.gif, tour.mp4')
}

async function main() {
  await mkdir(VIDEO_DIR, { recursive: true })
  for (const entry of await readdir(VIDEO_DIR)) await unlink(`${VIDEO_DIR}/${entry}`)
  for (const name of ['tour.webm', 'tour.gif', 'tour.mp4']) {
    if (existsSync(`${OUT}/${name}`)) await unlink(`${OUT}/${name}`)
  }

  const browser = await chromium.launch()
  const context = await browser.newContext({
    viewport: SIZE,
    deviceScaleFactor: 1,
    colorScheme: 'dark',
    recordVideo: { dir: VIDEO_DIR, size: SIZE },
  })
  await context.addInitScript(() => window.localStorage.setItem('pv-theme', 'dark'))

  await signIn(context)
  const { portfolios } = await (await context.request.get(`${BASE_URL}/api/v1/portfolios`)).json()
  const growth = portfolios.find((p) => p.name === 'Core Growth')
  if (!growth) throw new Error('demo data missing — run "bin/rails demo:seed"')

  // Recording starts with the page, so navigate immediately: a new page is a white
  // document, and one white frame at the head of a LOOPING gif reads as a flash.
  // The conversion also trims the first fraction of a second.
  const page = await context.newPage()

  // 1. The overview, with its sparklines.
  await page.goto(`${BASE_URL}/portfolios`)
  await beat(page, 1400)

  // 2. Into the dashboard: tiles, then the linked chart.
  await page.goto(`${BASE_URL}/portfolios/${growth.id}?range=6M`)
  await page.locator('canvas').first().waitFor()
  await beat(page, 1300)

  // 3. Read a single day across all three panes. Nudged down first so the tooltip
  //    has room to open below the crosshair instead of running off the frame.
  await glideTo(page, 230, 700)
  await beat(page, 400)
  await sweepTooltip(page)

  // 4. Turn the benchmark on — the feature the app exists for.
  await page.getByRole('switch', { name: 'Compare to benchmark' }).click()
  await beat(page, 1400)

  // 5. Widen to the whole history.
  await page.getByRole('button', { name: 'ALL', exact: true }).click()
  await beat(page, 1500)

  // 6. Pan down through contributions, the donuts and the treemap.
  await glideTo(page, 900, 1000)
  await beat(page, 900)
  await glideTo(page, 1650, 1000)
  await beat(page, 1000)
  await glideTo(page, 2350, 1000)
  await beat(page, 1200)

  await context.close()
  await browser.close()

  const [file] = await readdir(VIDEO_DIR)
  const webm = `${OUT}/tour.webm`
  await rename(`${VIDEO_DIR}/${file}`, webm)
  console.log(`  → tour.webm`)
  await convert(webm)
}

await main()
