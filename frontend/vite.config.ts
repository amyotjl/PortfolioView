import { fileURLToPath, URL } from 'node:url'
import { defineConfig } from 'vite'
import vue from '@vitejs/plugin-vue'
import tailwindcss from '@tailwindcss/vite'

// https://vite.dev/config/
export default defineConfig({
  plugins: [vue(), tailwindcss()],
  resolve: {
    alias: {
      '@': fileURLToPath(new URL('./src', import.meta.url)),
    },
  },
  server: {
    host: true,
    port: 5173,
    // The e2e container reaches this server by its compose service name, and
    // Vite's DNS-rebinding guard 403s any Host header it doesn't recognize.
    // Allow exactly that one name — NOT `true`/`'all'`, which would disable the
    // guard entirely for a dev server that is also published on the host.
    allowedHosts: ['vite'],
    proxy: {
      // Same-origin in the browser; Rails handles /api. Inside docker compose the
      // Rails service is reachable as "web", on a bare host as localhost.
      '/api': {
        target: process.env.VITE_API_PROXY_TARGET ?? 'http://localhost:3000',
        changeOrigin: false,
      },
    },
  },
})
