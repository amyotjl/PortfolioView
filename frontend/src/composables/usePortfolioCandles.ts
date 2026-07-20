import { computed, toValue, type MaybeRefOrGetter } from 'vue'
import { useQuery } from '@pinia/colada'
import { apiGet } from '@/api/client'
import { candlesResponseSchema } from '@/types'

export interface CandlesRange {
  from?: string
  to?: string
}

export interface CandlesQueryOptions {
  /** Request the cash-flow-matched benchmark line (adds `benchmark=true`). */
  benchmark?: MaybeRefOrGetter<boolean>
}

/**
 * Per-portfolio candles (GET /portfolios/:id/candles), keyed
 * `['candles', pid, from, to, benchmark]` (the plan's `['candles', pid, from,
 * to]` convention extended with the benchmark flag so toggling it is a separate
 * cache entry, not a stale hit). The portfolio cards use it for close-value
 * sparklines (no benchmark, full history); the M6 dashboard passes a windowed
 * range and `benchmark: true` and reads the full payload from `data`.
 */
export function usePortfolioCandlesQuery(
  portfolioId: MaybeRefOrGetter<number>,
  range: MaybeRefOrGetter<CandlesRange> = () => ({}),
  options: CandlesQueryOptions = {},
) {
  const query = useQuery({
    key: () => {
      const { from, to } = toValue(range)
      return ['candles', toValue(portfolioId), from ?? null, to ?? null, toValue(options.benchmark) ?? false]
    },
    query: () => {
      const { from, to } = toValue(range)
      const benchmark = toValue(options.benchmark) ?? false
      return apiGet(`/portfolios/${toValue(portfolioId)}/candles`, {
        schema: candlesResponseSchema,
        query: { from, to, benchmark: benchmark ? true : undefined },
      })
    },
    enabled: () => toValue(portfolioId) > 0,
  })

  /** Close values as numbers — for sparkline GEOMETRY only (never money math). */
  const closes = computed<number[]>(() => query.data.value?.candles.map((c) => Number(c.c)) ?? [])

  /** Latest close as the raw decimal string, so the displayed value stays exact. */
  const latestClose = computed<string | null>(() => {
    const candles = query.data.value?.candles
    return candles && candles.length > 0 ? candles[candles.length - 1].c : null
  })

  return { ...query, closes, latestClose }
}
