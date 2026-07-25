import { shallowRef } from 'vue'
import { ApiError, apiGet } from '@/api/client'
import {
  holdingResponseSchema,
  instrumentSearchSchema,
  priceResponseSchema,
  type InstrumentSearchResult,
} from '@/types'

/**
 * The three id-addressed lookups the transaction drawer makes while the user
 * types: directory autocomplete, cached-close prefill, and the sell pre-flight.
 *
 * These are imperative rather than `useQuery` on purpose — each fires in
 * response to a specific user event (typing a ticker, changing symbol/date,
 * changing shares) and the result belongs to the form's local state, not to a
 * shared server-state cache that other components read. Autocomplete responses
 * in particular should not accumulate in the query cache keyed by every prefix
 * the user typed through.
 *
 * Every request is abortable and last-write-wins: a slower earlier response can
 * never overwrite a newer one (the classic autocomplete race).
 */

/** The API 422s below this; don't spend a request to find that out. */
const MIN_SEARCH_LENGTH = 2

export function useInstrumentSearch() {
  const results = shallowRef<InstrumentSearchResult[]>([])
  const isSearching = shallowRef(false)
  let controller: AbortController | null = null

  async function search(term: string): Promise<void> {
    const q = term.trim()
    controller?.abort()

    if (q.length < MIN_SEARCH_LENGTH) {
      results.value = []
      isSearching.value = false
      return
    }

    const current = new AbortController()
    controller = current
    isSearching.value = true
    try {
      const data = await apiGet('/instruments/search', {
        query: { q },
        schema: instrumentSearchSchema,
        signal: current.signal,
      })
      // Ignore a response that a newer keystroke has already superseded.
      if (controller !== current) return
      results.value = data.instruments
    } catch {
      // An aborted or failed lookup shows an empty list rather than an error —
      // the user is mid-typing and the server still validates the final symbol.
      if (controller === current) results.value = []
    } finally {
      if (controller === current) isSearching.value = false
    }
  }

  return { results, isSearching, search }
}

/**
 * Cached close for prefill. Resolves to null (never throws) for the two expected
 * misses: a symbol this portfolio has never traded, so we have no instrument_id
 * (see lib/instrumentIds.ts), and a date before the instrument's price history,
 * which the API answers as 404 `price_unavailable`. Both mean "we have nothing
 * to prefill" — the user types the real fill price, which is what they should
 * enter anyway.
 *
 * Returns the WHOLE price row, not just the close. `price.date` is the trading
 * day the server actually used (<= requested), which is the only signal the
 * client gets about how far the trading calendar reaches — and the sell
 * pre-flight needs it to know whether its own answer is current. See
 * `effectiveDate` handling in TransactionFormDrawer.
 */
export function useInstrumentPrice() {
  const isLoading = shallowRef(false)
  let controller: AbortController | null = null

  async function fetchPrice(
    instrumentId: number | null,
    date: string,
  ): Promise<{ close: string; date: string } | null> {
    controller?.abort()
    if (!instrumentId || !/^\d{4}-\d{2}-\d{2}$/.test(date)) return null

    const current = new AbortController()
    controller = current
    isLoading.value = true
    try {
      const data = await apiGet(`/instruments/${instrumentId}/price`, {
        query: { date },
        schema: priceResponseSchema,
        signal: current.signal,
      })
      if (controller !== current) return null
      return { close: data.price.close, date: data.price.date }
    } catch (error) {
      if (error instanceof ApiError && error.code === 'price_unavailable') return null
      return null
    } finally {
      if (controller === current) isLoading.value = false
    }
  }

  return { isLoading, fetchPrice }
}

/**
 * Sell pre-flight: shares held at the last trading day <= as_of. Returns the
 * decimal string as-is, or null if the lookup failed.
 *
 * ADVISORY ONLY — docs/PLAN.md is explicit that the server stays authoritative.
 * This warns early on the obvious case, but the real guard is the model's
 * split-adjusted replay across the whole timeline, which also catches backdated
 * edits this single-date check cannot see. A null here must never be read as
 * "the sell is fine".
 *
 * IT IS ALSO CALENDAR-QUANTIZED, which the caller has to account for. The
 * endpoint computes the position at the last trading day <= as_of, but the
 * server's validator replays by transaction date. So a transaction dated after
 * the newest cached price — i.e. any trade made before today's close, or on a
 * weekend — is invisible here: buy 10 shares today, ask for today's position,
 * and this still answers "0.0". Verified live against the dev stack. Treating
 * that as a shortfall would fire a false warning in the common case, so the
 * drawer only asserts a shortfall when the position's effective date matches the
 * date being sold.
 */
export function useHoldingPreflight() {
  const isLoading = shallowRef(false)
  let controller: AbortController | null = null

  async function fetchShares(
    portfolioId: number,
    instrumentId: number | null,
    asOf: string,
  ): Promise<string | null> {
    controller?.abort()
    if (!portfolioId || !instrumentId || !/^\d{4}-\d{2}-\d{2}$/.test(asOf)) return null

    const current = new AbortController()
    controller = current
    isLoading.value = true
    try {
      const data = await apiGet(`/portfolios/${portfolioId}/holdings`, {
        query: { instrument_id: instrumentId, as_of: asOf },
        schema: holdingResponseSchema,
        signal: current.signal,
      })
      if (controller !== current) return null
      return data.holding.shares
    } catch {
      return null
    } finally {
      if (controller === current) isLoading.value = false
    }
  }

  return { isLoading, fetchShares }
}

/** Autocomplete row label: name is null on every directory row today (#63). */
export function instrumentLabel(instrument: InstrumentSearchResult): string {
  const detail = [instrument.exchange, instrument.asset_type].filter(Boolean).join(' · ')
  return detail ? `${instrument.symbol} — ${detail}` : instrument.symbol
}
