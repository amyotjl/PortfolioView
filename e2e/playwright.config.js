import { defineConfig, devices } from '@playwright/test'

/**
 * Playwright config for the e2e smoke suite (issue #51).
 *
 * Runs INSIDE a container on the compose network, so the default baseURL is the
 * service name `vite:5173` rather than localhost — that keeps the suite off the
 * host's published ports (3000/5173/5433 belong to the primary dev stack, and
 * per the root CLAUDE.md ad-hoc containers must never republish them).
 *
 * NOT a `webServer` config: the suite tests the real dev stack that is already
 * running, rather than booting a second one that would collide with it.
 */

const BASE_URL = process.env.E2E_BASE_URL ?? 'http://vite:5173'

export default defineConfig({
  testDir: '.',
  testMatch: '**/*.spec.js',

  /**
   * retries: 0 is deliberate. Issue #51 requires the suite to pass 3 consecutive
   * runs WITHOUT flakes — retries would hide exactly the flakiness that criterion
   * exists to detect. Add retries only if this ever runs on shared CI hardware,
   * and treat needing them as a bug in the suite.
   */
  retries: 0,

  /**
   * One worker. The smoke path registers a user, and registration is rate-limited
   * to 10 per 3 minutes (RegistrationsController); parallel workers would race
   * that budget and surface as spurious 429s. The suite is small enough that
   * serial execution costs little.
   */
  workers: 1,
  fullyParallel: false,

  // Fail the run if a test was accidentally committed with .only.
  forbidOnly: Boolean(process.env.CI),

  timeout: 60_000,
  expect: { timeout: 15_000 },

  reporter: [['list'], ['html', { open: 'never', outputFolder: 'playwright-report' }]],

  use: {
    baseURL: BASE_URL,
    headless: true,
    // Artifacts only for failures — a green run leaves nothing behind.
    trace: 'retain-on-failure',
    screenshot: 'only-on-failure',
    video: 'off',
    actionTimeout: 15_000,
    navigationTimeout: 30_000,
  },

  projects: [{ name: 'chromium', use: { ...devices['Desktop Chrome'] } }],
})
