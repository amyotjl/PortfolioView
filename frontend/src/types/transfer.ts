import { z } from 'zod'

/**
 * Portfolio export/import (issue #64, docs/API_SHAPES.md § Export / import).
 *
 * Export returns a FILE, not JSON we parse — there is no schema for it here on
 * purpose. The SPA never inspects an export body; it hands the bytes straight to
 * the browser's download. Only the import REPORT is parsed.
 */

/** Per-portfolio outcome. `renamed` still means imported — just under a new name. */
export const IMPORT_STATUSES = ['created', 'renamed', 'skipped', 'failed'] as const
export type ImportStatus = (typeof IMPORT_STATUSES)[number]

/**
 * Not a z.enum: a future backend status must not make the whole response fail
 * schema validation (which in dev throws and blanks the dialog). Unknown values
 * fall through as plain strings and the UI treats them neutrally.
 */
export const importPortfolioResultSchema = z.object({
  /** The name the FILE asked for. */
  name: z.string(),
  /** The name it actually took — null when skipped or failed. */
  imported_as: z.string().nullable(),
  status: z.string(),
  transactions_created: z.number(),
  recurring_created: z.number(),
  errors: z.array(z.string()),
  warnings: z.array(z.string()),
})

export const importTotalsSchema = z.object({
  portfolios_created: z.number(),
  portfolios_skipped: z.number(),
  portfolios_failed: z.number(),
  transactions_created: z.number(),
  recurring_created: z.number(),
  /**
   * Corporate actions recorded (issue #68 — a broker activity ledger reports a
   * split as a share delta, which the parser converts back to a ratio).
   *
   * Instrument-GLOBAL, so it belongs to the run rather than to any portfolio row,
   * and `.default(0)` so a server predating #68 still parses (a schema failure
   * throws in dev and would blank the whole dialog).
   */
  splits_created: z.number().default(0),
})

export const importReportSchema = z.object({
  /** Which parser handled the file — the UI names the format it detected. */
  format: z.string(),
  dry_run: z.boolean(),
  totals: importTotalsSchema,
  /** File-level notes belonging to no single portfolio. */
  warnings: z.array(z.string()),
  portfolios: z.array(importPortfolioResultSchema),
})

export const importResponseSchema = z.object({
  import: importReportSchema,
})

export type ImportPortfolioResult = z.infer<typeof importPortfolioResultSchema>
export type ImportTotals = z.infer<typeof importTotalsSchema>
export type ImportReport = z.infer<typeof importReportSchema>
export type ImportResponse = z.infer<typeof importResponseSchema>

/** Mirrors Portfolios::Transfer::Import::ON_CONFLICT_MODES. */
export const ON_CONFLICT_MODES = ['rename', 'skip'] as const
export type OnConflictMode = (typeof ON_CONFLICT_MODES)[number]

/** Mirrors Portfolios::Transfer::MAX_FILE_BYTES — checked client-side too so an
 * oversized pick is refused before a pointless 8 MB upload. */
export const MAX_IMPORT_BYTES = 8 * 1024 * 1024

export const NATIVE_FORMAT = 'portfolioview.portfolios'
export const HOLDINGS_CSV_FORMAT = 'wealthsimple.holdings'
export const ACTIVITIES_CSV_FORMAT = 'wealthsimple.activities'

/**
 * Human label for the `format` the backend reports detecting. The two broker
 * labels are worded to make the difference obvious: an activity LEDGER carries a
 * real trade history, a holdings SNAPSHOT does not.
 */
export function formatLabel(format: string): string {
  if (format === NATIVE_FORMAT) return 'PortfolioView export'
  if (format === ACTIVITIES_CSV_FORMAT) return 'Broker activity ledger'
  if (format === HOLDINGS_CSV_FORMAT) return 'Broker holdings report'
  return format
}
