import { describe, expect, it } from 'vitest'
import {
  allWarnings,
  hasFailures,
  statusLabel,
  statusSeverity,
  summaryLine,
} from '@/lib/importSummary'
import type { ImportReport, ImportPortfolioResult } from '@/types'

/**
 * The import report is the only place a user learns that a portfolio was renamed
 * or a position dropped, so the wording is contract-grade — especially the rule
 * that a partly-failed run must never read as a clean success.
 */

function portfolio(overrides: Partial<ImportPortfolioResult> = {}): ImportPortfolioResult {
  return {
    name: 'TFSA',
    imported_as: 'TFSA',
    status: 'created',
    transactions_created: 1,
    recurring_created: 0,
    errors: [],
    warnings: [],
    ...overrides,
  }
}

function report(overrides: Partial<ImportReport> = {}): ImportReport {
  const portfolios = overrides.portfolios ?? [portfolio()]
  return {
    format: 'portfolioview.portfolios',
    dry_run: false,
    warnings: [],
    portfolios,
    totals: {
      portfolios_created: portfolios.filter((p) => ['created', 'renamed'].includes(p.status)).length,
      portfolios_skipped: portfolios.filter((p) => p.status === 'skipped').length,
      portfolios_failed: portfolios.filter((p) => p.status === 'failed').length,
      transactions_created: portfolios.reduce((sum, p) => sum + p.transactions_created, 0),
      recurring_created: portfolios.reduce((sum, p) => sum + p.recurring_created, 0),
      ...overrides.totals,
    },
    ...overrides,
  }
}

describe('statusSeverity / statusLabel', () => {
  it('maps every known status to a severity and a human label', () => {
    expect(statusSeverity('created')).toBe('info')
    expect(statusSeverity('renamed')).toBe('info')
    expect(statusSeverity('skipped')).toBe('warn')
    expect(statusSeverity('failed')).toBe('danger')

    expect(statusLabel('created')).toBe('Imported')
    expect(statusLabel('renamed')).toBe('Renamed')
    expect(statusLabel('skipped')).toBe('Skipped')
    expect(statusLabel('failed')).toBe('Failed')
  })

  it('degrades gracefully for a status this build does not know', () => {
    // The schema keeps `status` a plain string so a newer backend cannot make the
    // whole response fail validation and blank the dialog.
    expect(statusSeverity('quarantined')).toBe('secondary')
    expect(statusLabel('quarantined')).toBe('quarantined')
  })
})

describe('summaryLine', () => {
  it('reports a clean import with pluralized counts', () => {
    const line = summaryLine(
      report({ portfolios: [portfolio({ transactions_created: 3 }), portfolio({ name: 'RRSP', transactions_created: 1 })] }),
    )

    expect(line).toBe('Imported 2 portfolios with 4 transactions.')
  })

  it('uses singular forms for one of each', () => {
    expect(summaryLine(report())).toBe('Imported 1 portfolio with 1 transaction.')
  })

  it('mentions recurring rules only when there are some', () => {
    expect(summaryLine(report())).not.toContain('recurring')
    expect(summaryLine(report({ portfolios: [portfolio({ recurring_created: 2 })] }))).toBe(
      'Imported 1 portfolio with 1 transaction and 2 recurring rules.',
    )
  })

  it('NEVER lets a partly-failed run read as a clean success', () => {
    const line = summaryLine(
      report({ portfolios: [portfolio(), portfolio({ name: 'Bad', status: 'failed', transactions_created: 0, errors: ['nope'] })] }),
    )

    expect(line).toContain('1 portfolio failed')
  })

  it('reports skips alongside successes', () => {
    const line = summaryLine(
      report({ portfolios: [portfolio(), portfolio({ name: 'Dup', status: 'skipped', transactions_created: 0 })] }),
    )

    expect(line).toContain('1 portfolio skipped')
  })

  it('reports both failures and skips', () => {
    const line = summaryLine(
      report({
        portfolios: [
          portfolio(),
          portfolio({ name: 'Bad', status: 'failed', transactions_created: 0 }),
          portfolio({ name: 'Dup', status: 'skipped', transactions_created: 0 }),
        ],
      }),
    )

    expect(line).toContain('1 portfolio failed and 1 portfolio skipped')
  })

  it('says nothing was imported when everything failed', () => {
    const line = summaryLine(
      report({ portfolios: [portfolio({ status: 'failed', transactions_created: 0 })] }),
    )

    expect(line).toBe('Nothing was imported. 1 portfolio failed.')
  })

  it('phrases a dry run as hypothetical, never as done', () => {
    const line = summaryLine(report({ dry_run: true }))

    expect(line).toBe('This file would import 1 portfolio with 1 transaction.')
    expect(line).not.toContain('Imported ')
  })

  it('handles an empty file', () => {
    expect(summaryLine(report({ portfolios: [] }))).toBe('This file contained no portfolios to import.')
  })
})

describe('hasFailures', () => {
  it('is true only when a portfolio failed', () => {
    expect(hasFailures(report())).toBe(false)
    expect(
      hasFailures(report({ portfolios: [portfolio({ status: 'failed', transactions_created: 0 })] })),
    ).toBe(true)
  })
})

describe('allWarnings', () => {
  it('lists file-level notes first, then labels per-portfolio ones', () => {
    const rows = allWarnings(
      report({
        warnings: ['the report had no As of date'],
        portfolios: [portfolio({ name: 'TFSA', warnings: ['renamed to TFSA (imported)'] })],
      }),
    )

    expect(rows).toEqual([
      { scope: null, message: 'the report had no As of date' },
      { scope: 'TFSA', message: 'renamed to TFSA (imported)' },
    ])
  })

  it('is empty when there is nothing to say', () => {
    expect(allWarnings(report())).toEqual([])
  })
})
