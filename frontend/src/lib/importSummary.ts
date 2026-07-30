import type { ImportReport, ImportStatus } from '@/types'

/**
 * Presentation helpers for the import report (issue #64). Pure and DOM-free so
 * the wording — which is the only place a user learns that a portfolio was
 * renamed or a position dropped — is unit-testable.
 */

/** Tag severity per outcome. `danger` marks a failure, never a value. */
export function statusSeverity(status: string): 'info' | 'warn' | 'danger' | 'secondary' {
  switch (status) {
    case 'created':
    case 'renamed':
      return 'info'
    case 'skipped':
      return 'warn'
    case 'failed':
      return 'danger'
    default:
      return 'secondary'
  }
}

export function statusLabel(status: string): string {
  switch (status) {
    case 'created':
      return 'Imported'
    case 'renamed':
      return 'Renamed'
    case 'skipped':
      return 'Skipped'
    case 'failed':
      return 'Failed'
    default:
      return status
  }
}

function plural(count: number, singular: string, pluralForm = `${singular}s`): string {
  return `${count} ${count === 1 ? singular : pluralForm}`
}

/**
 * One-line headline. Deliberately leads with the FAILURE count when there is
 * one: a bulk import that partly failed must not read as a success.
 */
export function summaryLine(report: ImportReport): string {
  const { portfolios_created, portfolios_skipped, portfolios_failed, transactions_created } =
    report.totals

  if (portfolios_created === 0 && portfolios_failed === 0 && portfolios_skipped === 0) {
    return 'This file contained no portfolios to import.'
  }

  const verb = report.dry_run ? 'would import' : 'Imported'
  const parts: string[] = []

  if (portfolios_created > 0) {
    parts.push(`${plural(portfolios_created, 'portfolio')} with ${plural(transactions_created, 'transaction')}`)
  }
  if (report.totals.recurring_created > 0) {
    parts.push(plural(report.totals.recurring_created, 'recurring rule'))
  }
  if (report.totals.splits_created > 0) {
    // Worth naming in the headline: a split changes share counts for EVERY
    // portfolio holding the instrument, not just the ones in this file.
    parts.push(plural(report.totals.splits_created, 'stock split'))
  }

  const head = report.dry_run
    ? parts.length > 0
      ? `This file ${verb} ${joinList(parts)}.`
      : 'This file would import nothing.'
    : parts.length > 0
      ? `${verb} ${joinList(parts)}.`
      : 'Nothing was imported.'

  const tail: string[] = []
  if (portfolios_failed > 0) tail.push(`${plural(portfolios_failed, 'portfolio')} failed`)
  if (portfolios_skipped > 0) tail.push(`${plural(portfolios_skipped, 'portfolio')} skipped`)

  return tail.length > 0 ? `${head} ${capitalize(joinList(tail))}.` : head
}

function joinList(parts: string[]): string {
  if (parts.length <= 1) return parts[0] ?? ''
  return `${parts.slice(0, -1).join(', ')} and ${parts[parts.length - 1]}`
}

function capitalize(value: string): string {
  return value.charAt(0).toUpperCase() + value.slice(1)
}

/** Any failure at all — drives the banner's tone. */
export function hasFailures(report: ImportReport): boolean {
  return report.totals.portfolios_failed > 0
}

/** Every warning in the run, file-level first, each labelled with its portfolio. */
export function allWarnings(report: ImportReport): Array<{ scope: string | null; message: string }> {
  const rows: Array<{ scope: string | null; message: string }> = report.warnings.map((message) => ({
    scope: null,
    message,
  }))

  for (const portfolio of report.portfolios) {
    for (const message of portfolio.warnings) {
      rows.push({ scope: portfolio.name, message })
    }
  }
  return rows
}

export const KNOWN_STATUSES: readonly ImportStatus[] = ['created', 'renamed', 'skipped', 'failed']
