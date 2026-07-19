import { createApp } from 'vue'
import { createPinia } from 'pinia'
import { PiniaColada } from '@pinia/colada'
import PrimeVue from 'primevue/config'
import App from './App.vue'
import router from './router'
import { setUnauthorizedHandler } from './api/client'
import { useAuthStore } from './stores/auth'
import './assets/main.css'

const app = createApp(App)

// Pinia (client-owned state) + Pinia Colada (server-state query caches).
const pinia = createPinia()
app.use(pinia)
app.use(PiniaColada)

app.use(router)

// PrimeVue in unstyled mode — components carry no built-in CSS; styling comes
// from Tailwind + the tailwindcss-primeui preset (pass-through presets land with
// the form components in #038).
app.use(PrimeVue, { unstyled: true })

// When any API call 401s, drop the local session and route to /login (SPA-aware,
// preserving the intended destination) instead of a hard page reload.
setUnauthorizedHandler(() => {
  const auth = useAuthStore()
  auth.clear()
  if (router.currentRoute.value.name !== 'login') {
    router.push({
      name: 'login',
      query: { redirect: router.currentRoute.value.fullPath },
    })
  }
})

app.mount('#app')
