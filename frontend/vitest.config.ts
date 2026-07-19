import { fileURLToPath, URL } from 'node:url'
import { defineConfig } from 'vitest/config'

/**
 * Minimal Vitest config for the schema unit tests added with #037. A fuller
 * setup (jsdom, component testing, coverage) lands with the tester issue; kept
 * deliberately small here. `node` environment is enough for pure-schema tests.
 */
export default defineConfig({
  resolve: {
    alias: {
      '@': fileURLToPath(new URL('./src', import.meta.url)),
    },
  },
  test: {
    environment: 'node',
    include: ['src/**/*.spec.ts'],
  },
})
