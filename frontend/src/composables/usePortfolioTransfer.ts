import { useMutation, useQueryCache } from '@pinia/colada'
import { apiDownload, apiUpload } from '@/api/client'
import { saveBlob } from '@/lib/download'
import { importResponseSchema, type ImportReport, type OnConflictMode } from '@/types'
import { PORTFOLIOS_KEY } from '@/composables/usePortfolios'
import { TRANSACTIONS_KEY } from '@/composables/useTransactions'

/**
 * Portfolio export / import (issue #64).
 *
 * Export is a mutation rather than a query on purpose: it has a side effect (a
 * file lands on disk), must never be cached or refetched, and must not run on
 * mount.
 */

export interface ImportInput {
  file: File
  onConflict?: OnConflictMode
  /** Preview only — the server rolls its transaction back. */
  dryRun?: boolean
}

export function useExportPortfolios() {
  return useMutation({
    mutation: async (portfolioIds?: number[]) => {
      const query =
        portfolioIds && portfolioIds.length > 0
          ? // Rails reads repeated `portfolio_ids[]` params as an array; the client's
            // QueryParams is scalar-only, so the list is joined and split server-side
            // via the same bracket convention.
            Object.fromEntries(portfolioIds.map((id, i) => [`portfolio_ids[${i}]`, id]))
          : undefined

      const { blob, filename } = await apiDownload('/portfolios/export', fallbackFilename(), { query })
      saveBlob(blob, filename)
      return filename
    },
  })
}

/** Only used if the response somehow carries no Content-Disposition. */
function fallbackFilename(): string {
  return `portfolioview-portfolios-${new Date().toISOString().slice(0, 10)}.json`
}

export function useImportPortfolios() {
  const cache = useQueryCache()

  return useMutation({
    mutation: async ({ file, onConflict = 'rename', dryRun = false }: ImportInput): Promise<ImportReport> => {
      const form = new FormData()
      form.append('file', file)
      form.append('on_conflict', onConflict)
      form.append('dry_run', String(dryRun))

      const response = await apiUpload('/portfolios/import', form, { schema: importResponseSchema })
      return response.import
    },
    onSuccess: (report) => {
      // A preview wrote nothing, so invalidating would refetch for no reason.
      if (report.dry_run) return
      // An import creates portfolios AND their transactions, and the server bumps
      // series_version — so the same keys a transaction mutation invalidates must
      // be dropped here (docs/STATUS.md § frontend building blocks).
      //
      // Invalidated by PREFIX and without a portfolio id, unlike useTransactions'
      // per-portfolio helper: an import touches portfolios this client has never
      // seen, so there is no id list to iterate.
      cache.invalidateQueries({ key: [...PORTFOLIOS_KEY] })
      for (const key of [TRANSACTIONS_KEY, 'candles', 'summary', 'allocations']) {
        cache.invalidateQueries({ key: [key] })
      }
    },
  })
}

/** True when the run changed the database and the UI should offer a way onward. */
export function importChangedAnything(report: ImportReport): boolean {
  return !report.dry_run && report.totals.portfolios_created > 0
}
