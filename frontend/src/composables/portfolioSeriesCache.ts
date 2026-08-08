import type { useQueryCache } from '@pinia/colada'
import { PORTFOLIOS_KEY } from '@/composables/usePortfolios'

/**
 * THE one place that invalidates a portfolio's derived server state.
 *
 * Every ledger mutation — a trade, a recurring rule, and now a cash movement —
 * moves the portfolio's whole derived series: the backend bumps `series_version`,
 * which drops the server-side caches for candles/summary/allocations. The client
 * has to mirror that or the dashboard silently shows pre-mutation numbers. Miss
 * one key and the bug is invisible on the page you mutated from and only shows up
 * as a stale dashboard somewhere else.
 *
 * WHY THIS FILE EXISTS. `useTransactions.ts` used to claim to be "the one place
 * that invalidates all series keys" while `useRecurringTransactions.ts` carried a
 * hand-copied second instance of the same list — so the claim was already false
 * before cash arrived, and cash would have made it a third copy. The helper is
 * extracted here (rather than living in one of the composables) so all of them
 * can import it without an import cycle; that is also why the query-key constants
 * live here.
 *
 * WHAT A CASH MUTATION ACTUALLY MOVES, spelled out because it is more than it
 * looks: `cash_balance`, `current_value`, `net_deposits`, `total_return(_pct)`,
 * `benchmark_return_pct` (cash IS the denominator), `vs_benchmark_edge_pct`,
 * `max_drawdown_pct`, and /candles' `flows` + `cash`. The FIRST cash transaction
 * additionally flips `deposit_basis`, which rewrites `flows` for the whole history
 * and changes which stat tiles exist at all.
 *
 * `transactions` and `allocations` are invalidated on the cash path too even
 * though a cash row changes neither. Trimming the set per mutation type is how the
 * divergence above got introduced in the first place; a redundant refetch is
 * cheaper than a class of invisible staleness bug.
 *
 * Sign-out needs nothing from here: `stores/auth.ts` iterates `getEntries()`
 * unfiltered, so a new `['cash', …]` key is covered by construction.
 */

export const TRANSACTIONS_KEY = 'transactions'
export const RECURRING_KEY = 'recurring'
export const CASH_KEY = 'cash'
export const CANDLES_KEY = 'candles'
export const SUMMARY_KEY = 'summary'
export const ALLOCATIONS_KEY = 'allocations'

/** Every per-portfolio key prefix a ledger mutation invalidates. */
const PORTFOLIO_SERIES_KEYS = [
  TRANSACTIONS_KEY,
  RECURRING_KEY,
  CASH_KEY,
  CANDLES_KEY,
  SUMMARY_KEY,
  ALLOCATIONS_KEY,
] as const

type QueryCache = ReturnType<typeof useQueryCache>

/**
 * Drop every cached series for one portfolio, plus the portfolios list (whose
 * payload carries `series_version` and whose cards render sparklines).
 *
 * Invalidated by PREFIX, so all pages of a paginated list and every date-range /
 * benchmark variant of the candles query are covered — not just the entry that
 * happens to be mounted.
 */
export function invalidatePortfolioSeries(cache: QueryCache, portfolioId: number): void {
  for (const key of PORTFOLIO_SERIES_KEYS) {
    cache.invalidateQueries({ key: [key, portfolioId] })
  }
  cache.invalidateQueries({ key: [...PORTFOLIOS_KEY] })
}

/**
 * The same set, but for every portfolio — used by an import, which creates
 * portfolios (and now cash rows) this client has never seen and so has no id list
 * to iterate.
 */
export function invalidateAllPortfolioSeries(cache: QueryCache): void {
  for (const key of PORTFOLIO_SERIES_KEYS) {
    cache.invalidateQueries({ key: [key] })
  }
  cache.invalidateQueries({ key: [...PORTFOLIOS_KEY] })
}
