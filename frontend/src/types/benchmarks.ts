import { z } from 'zod'

/**
 * GET /api/v1/benchmarks -> { benchmarks: [{ id, name, symbol }] } (seed order).
 */
export const benchmarkSchema = z.object({
  id: z.number(),
  name: z.string(),
  symbol: z.string(),
})

export const benchmarksSchema = z.object({
  benchmarks: z.array(benchmarkSchema),
})

export type Benchmark = z.infer<typeof benchmarkSchema>
export type Benchmarks = z.infer<typeof benchmarksSchema>
