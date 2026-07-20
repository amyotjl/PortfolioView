import { afterEach } from 'vitest'
import { cleanup } from '@testing-library/vue'

/**
 * Global test setup (wired via vitest.config.ts `setupFiles`). We import test
 * globals explicitly rather than enabling `globals: true`, so Testing Library's
 * automatic per-test cleanup is registered here to keep the happy-dom document
 * from leaking mounted components between specs.
 */
afterEach(() => {
  cleanup()
})
