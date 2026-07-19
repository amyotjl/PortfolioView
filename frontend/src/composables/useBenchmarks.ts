import { computed } from 'vue'
import { useQuery } from '@pinia/colada'
import { apiGet } from '@/api/client'
import { benchmarksSchema, type Benchmark } from '@/types'

/**
 * The curated benchmark list (GET /benchmarks) — a static seed, so it is cached
 * generously. Server state, so it lives in the Colada cache keyed `['benchmarks']`.
 */
export function useBenchmarksQuery() {
  const query = useQuery({
    key: () => ['benchmarks'],
    query: () => apiGet('/benchmarks', { schema: benchmarksSchema }),
    staleTime: 1000 * 60 * 60,
  })

  const benchmarks = computed<Benchmark[]>(() => query.data.value?.benchmarks ?? [])

  return { ...query, benchmarks }
}

/** Display label for a benchmark: `SPY · SPDR S&P 500 ETF`. */
export function benchmarkLabel(benchmark: Benchmark): string {
  return `${benchmark.symbol} · ${benchmark.name}`
}
