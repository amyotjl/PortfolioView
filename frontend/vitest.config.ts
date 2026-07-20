import { fileURLToPath, URL } from 'node:url'
import { defineConfig } from 'vitest/config'
import vue from '@vitejs/plugin-vue'

/**
 * Vitest is the frontend UNIT layer (pure functions, zod parsing, composables,
 * and component tests for components with real logic — see src/test/README.md).
 *
 * - `@vitejs/plugin-vue` gives `.vue` SFC support so components can be mounted.
 * - `happy-dom` provides the DOM for component tests (lighter than jsdom); the
 *   pure specs run fine in it too.
 * - Coverage uses the v8 provider and writes text + HTML + lcov reports.
 */
export default defineConfig({
  plugins: [vue()],
  resolve: {
    alias: {
      '@': fileURLToPath(new URL('./src', import.meta.url)),
    },
  },
  test: {
    environment: 'happy-dom',
    include: ['src/**/*.spec.ts'],
    setupFiles: ['src/test/setup.ts'],
    coverage: {
      provider: 'v8',
      reporter: ['text', 'html', 'lcov'],
      reportsDirectory: 'coverage',
      include: ['src/**/*.{ts,vue}'],
      exclude: [
        'src/**/*.spec.ts',
        'src/test/**',
        'src/main.ts',
        'src/types/index.ts',
        'src/**/*.d.ts',
      ],
    },
  },
})
