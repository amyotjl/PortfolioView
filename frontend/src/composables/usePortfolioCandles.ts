import { computed, toValue, type MaybeRefOrGetter } from 'vue'
import { useQuery } from '@pinia/colada'
import { apiGet } from '@/api/client'
import { candlesResponseSchema } from '@/types'

export interface CandlesRange {
  from?: string
  to?: string
}

/**
 * Per-portfolio candles (GET /portfolios/:id/candles), keyed
 * `['candles', pid, from, to]` per the plan's cache-key convention. The cards
 * use it for close-value sparklines (no benchmark, no range = full history); the
 * M6 dashboard batch can reuse this same query, passing a range and adding
 * `benchmark: true` to the request.
 */
export function usePortfolioCandlesQuery(
  portfolioId: MaybeRefOrGetter<number>,
  range: MaybeRefOrGetter<CandlesRange> = () => ({}),
) {
  const query = useQuery({
    key: () => {
      const { from, to } = toValue(range)
      return ['candles', toValue(portfolioId), from ?? null, to ?? null]
    },
    query: () => {
      const { from, to } = toValue(range)
      return apiGet(`/portfolios/${toValue(portfolioId)}/candles`, {
        schema: candlesResponseSchema,
        query: { from, to },
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
