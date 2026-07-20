import type { LocationQueryValue, RouteLocationRaw } from 'vue-router'

/**
 * Resolve the post-auth destination from a `?redirect=` query value, rejecting
 * anything that isn't a same-origin absolute path. Guards against open-redirect
 * (`//evil.com`, `https://…`) and array/empty query values, falling back to the
 * portfolios list. The router guard sets `?redirect=` to the intended fullPath.
 */
export function safeRedirectTarget(
  raw: LocationQueryValue | LocationQueryValue[] | undefined,
  fallback: RouteLocationRaw = { name: 'portfolios' },
): RouteLocationRaw {
  const value = Array.isArray(raw) ? raw[0] : raw
  if (typeof value === 'string' && value.startsWith('/') && !value.startsWith('//')) {
    return value
  }
  return fallback
}
