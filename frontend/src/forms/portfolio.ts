import { z } from 'zod'

/**
 * Client-side schema for the portfolio create/edit form. `benchmark_id` is a
 * curated benchmark id or null ("No benchmark"); the server validates that the
 * id references a seeded benchmark and returns a 422 on `benchmark_id` if not.
 */
export const portfolioFormSchema = z.object({
  name: z.string().min(1, 'Name is required').max(120, 'Keep the name under 120 characters'),
  benchmark_id: z.number().int().nullable(),
})

export type PortfolioFormValues = z.infer<typeof portfolioFormSchema>
