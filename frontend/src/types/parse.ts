import { z } from 'zod'

/**
 * Thrown when a response fails schema validation in development. Carries the
 * originating context (e.g. "GET /portfolios") and the underlying ZodError.
 */
export class SchemaValidationError extends Error {
  readonly context: string
  readonly issues: z.ZodError['issues']

  constructor(context: string, error: z.ZodError) {
    super(`Response for "${context}" did not match its schema`)
    this.name = 'SchemaValidationError'
    this.context = context
    this.issues = error.issues
  }
}

function summarize(error: z.ZodError): string {
  return error.issues
    .map((issue) => `${issue.path.join('.') || '(root)'}: ${issue.message}`)
    .join('; ')
}

/**
 * Parse a response body through its zod schema at the network boundary.
 *
 * - In dev (`import.meta.env.DEV`): FAIL LOUDLY — throw `SchemaValidationError`
 *   so contract drift surfaces immediately during development and tests.
 * - In prod: LOG, DON'T THROW — a schema mismatch shouldn't take down the app;
 *   we log to the console and pass the raw payload through as a best effort so
 *   the user still sees (possibly degraded) data instead of a blank screen.
 */
export function parseResponse<S extends z.ZodType>(
  schema: S,
  data: unknown,
  context: string,
): z.infer<S> {
  const result = schema.safeParse(data)
  if (result.success) return result.data

  if (import.meta.env.DEV) {
    console.error(`[api] schema validation failed for ${context}: ${summarize(result.error)}`)
    throw new SchemaValidationError(context, result.error)
  }

  console.error(
    `[api] schema validation failed for ${context}: ${summarize(result.error)} — passing raw payload through`,
  )
  return data as z.infer<S>
}
