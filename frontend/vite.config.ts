import { defineConfig } from 'vite'
import vue from '@vitejs/plugin-vue'

// https://vite.dev/config/
export default defineConfig({
  plugins: [vue()],
  server: {
    host: true,
    port: 5173,
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
