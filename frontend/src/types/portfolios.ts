import { z } from 'zod'
import { IsoDateTime } from './common'

/**
 * Single:  { portfolio: { id, name, benchmark_id, series_version, created_at, updated_at } }
 * Index:   { portfolios: [ ...single... ] }
 * `benchmark_id` is nullable; `series_version` is the chart cache-buster.
 */
export const portfolioSchema = z.object({
  id: z.number(),
  name: z.string(),
  benchmark_id: z.number().nullable(),
  series_version: z.number(),
  created_at: IsoDateTime,
  updated_at: IsoDateTime,
})

export const portfolioResponseSchema = z.object({
  portfolio: portfolioSchema,
})

export const portfoliosResponseSchema = z.object({
  portfolios: z.array(portfolioSchema),
})

export type Portfolio = z.infer<typeof portfolioSchema>
export type PortfolioResponse = z.infer<typeof portfolioResponseSchema>
export type PortfoliosResponse = z.infer<typeof portfoliosResponseSchema>
