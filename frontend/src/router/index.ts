import { createRouter, createWebHistory, type RouteRecordRaw } from 'vue-router'
import { useAuthStore } from '@/stores/auth'
import { useActivePortfolioStore } from '@/stores/active-portfolio'

/**
 * `layout: 'auth'` renders the centered AuthLayout; everything else defaults to
 * the AppShell. `public: true` marks routes reachable while signed out.
 */
declare module 'vue-router' {
  interface RouteMeta {
    layout?: 'app' | 'auth'
    public?: boolean
  }
}

const routes: RouteRecordRaw[] = [
  { path: '/', redirect: { name: 'portfolios' } },
  {
    path: '/login',
    name: 'login',
    component: () => import('@/views/LoginView.vue'),
    meta: { layout: 'auth', public: true },
  },
  {
    path: '/register',
    name: 'register',
    component: () => import('@/views/RegisterView.vue'),
    meta: { layout: 'auth', public: true },
  },
  {
    path: '/portfolios',
    name: 'portfolios',
    component: () => import('@/views/PortfoliosView.vue'),
  },
  {
    path: '/portfolios/:id',
    name: 'portfolio-dashboard',
    component: () => import('@/views/PortfolioDashboardView.vue'),
    props: true,
  },
  {
    path: '/portfolios/:id/transactions',
    name: 'portfolio-transactions',
    component: () => import('@/views/TransactionsView.vue'),
    props: true,
  },
  {
    path: '/portfolios/:id/recurring',
    name: 'portfolio-recurring',
    component: () => import('@/views/RecurringView.vue'),
    props: true,
  },
  {
    path: '/settings',
    name: 'settings',
    component: () => import('@/views/SettingsView.vue'),
  },
  {
    path: '/:pathMatch(.*)*',
    name: 'not-found',
    component: () => import('@/views/NotFoundView.vue'),
  },
]

const router = createRouter({
  history: createWebHistory(),
  routes,
  scrollBehavior: () => ({ top: 0 }),
})

router.beforeEach(async (to) => {
  const auth = useAuthStore()
  // Boot the session from GET /session on first navigation.
  if (auth.status === 'idle') await auth.bootstrap()

  // Keep the active-portfolio selection in sync with the route param.
  const idParam = Array.isArray(to.params.id) ? to.params.id[0] : to.params.id
  const activePortfolio = useActivePortfolioStore()
  if (idParam) {
    const parsed = Number(idParam)
    activePortfolio.setActive(Number.isNaN(parsed) ? null : parsed)
  } else if (to.name === 'portfolios') {
    activePortfolio.setActive(null)
  }

  const isPublic = to.meta.public === true
  if (!auth.isAuthenticated && !isPublic) {
    return { name: 'login', query: to.fullPath === '/' ? {} : { redirect: to.fullPath } }
  }
  if (auth.isAuthenticated && isPublic) {
    return { name: 'portfolios' }
  }
  return true
})

export default router
