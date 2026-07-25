import { describe, expect, it } from 'vitest'
import {
  allocationsResponseSchema,
  candlesResponseSchema,
  errorEnvelopeSchema,
  formatLabel,
  HOLDINGS_CSV_FORMAT,
  importReportSchema,
  importResponseSchema,
  instrumentSearchResultSchema,
  instrumentSearchSchema,
  MAX_IMPORT_BYTES,
  NATIVE_FORMAT,
  parseResponse,
  SchemaValidationError,
  summaryResponseSchema,
  transactionsResponseSchema,
} from './index'

describe('API contract schemas (docs/API_SHAPES.md)', () => {
  it('parses /candles as a BARE top-level object (no wrapper key)', () => {
    const payload = {
      candles: [{ t: '2026-01-02', o: '100.00', h: '101.50', l: '99.25', c: '100.75' }],
      benchmark: { symbol: 'SPY', values: [{ t: '2026-01-02', v: '470.10' }] },
      flows: [
        {
          t: '2026-01-02',
          net: '1000.00',
          items: [{ ticker: 'AAPL', kind: 'buy', amount: '1000.00' }],
        },
      ],
      drawdown: [{ t: '2026-01-02', v: '0.00000000' }],
      meta: { partial: false, filled_dates: [], benchmark_clamped: false, approximation: '' },
    }

    const parsed = parseResponse(candlesResponseSchema, payload, 'GET /candles')
    // Money/shares stay strings — never coerced to number.
    expect(typeof parsed.candles[0].c).toBe('string')
    expect(parsed.benchmark?.symbol).toBe('SPY')
    expect(parsed.flows[0].items[0].kind).toBe('buy')
  })

  it('parses /summary and /allocations as WRAPPED objects', () => {
    const summary = parseResponse(
      summaryResponseSchema,
      {
        summary: {
          current_value: '12345.67',
          net_deposits: '10000.00',
          total_return: '2345.67',
          total_return_pct: '0.234567',
          benchmark_return_pct: null,
          vs_benchmark_edge_pct: null,
          max_drawdown_pct: '0.101010',
          as_of: '2026-07-17',
        },
      },
      'GET /summary',
    )
    expect(summary.summary.benchmark_return_pct).toBeNull()

    const allocations = parseResponse(
      allocationsResponseSchema,
      {
        allocations: {
          as_of: '2026-07-17',
          total_value: '12345.67',
          by_instrument: [{ instrument_id: 1, symbol: 'AAPL', value: '6000.00', weight: '0.5' }],
          by_sector: [{ sector: 'ETF / Fund', value: '6345.67', weight: '0.5' }],
        },
      },
      'GET /allocations',
    )
    expect(allocations.allocations.by_instrument[0].weight).toBe('0.5')
  })

  it('parses the transactions index with pagination meta', () => {
    const parsed = parseResponse(
      transactionsResponseSchema,
      {
        transactions: [],
        meta: { page: 1, per_page: 50, total_count: 0, total_pages: 0 },
      },
      'GET /transactions',
    )
    expect(parsed.meta.per_page).toBe(50)
  })

  it('accepts instrument search rows with null name/exchange (only symbol is required)', () => {
    // Live directory rows always have name: null (Tiingo bulk import has no name
    // column); exchange/asset_type/currency may also be null. db/schema.rb makes
    // only `symbol` NOT NULL on listed_instruments.
    const parsed = parseResponse(
      instrumentSearchSchema,
      {
        instruments: [
          { symbol: 'AAPL', name: null, exchange: 'NASDAQ', asset_type: 'stock', currency: 'USD' },
          { symbol: 'ZZZ', name: null, exchange: null, asset_type: null, currency: null },
        ],
      },
      'GET /instruments/search',
    )
    expect(parsed.instruments[0].name).toBeNull()
    expect(parsed.instruments[1].exchange).toBeNull()
  })

  it('rejects an instrument search row with a null symbol', () => {
    const result = instrumentSearchResultSchema.safeParse({
      symbol: null,
      name: null,
      exchange: null,
      asset_type: null,
      currency: null,
    })
    expect(result.success).toBe(false)
  })

  it('parses the error envelope with a 422 field->messages map', () => {
    const parsed = errorEnvelopeSchema.parse({
      error: {
        code: 'validation_failed',
        message: 'Validation failed',
        details: { shares: ['must be greater than 0'], base: ['position would go negative'] },
      },
    })
    expect(parsed.error.details.shares).toEqual(['must be greater than 0'])
  })

  it('defaults missing error details to an empty object', () => {
    const parsed = errorEnvelopeSchema.parse({
      error: { code: 'not_found', message: 'Not found' },
    })
    expect(parsed.error.details).toEqual({})
  })

  it('fails loudly (throws) in dev on a contract mismatch', () => {
    // net_deposits missing -> invalid summary payload.
    expect(() =>
      parseResponse(summaryResponseSchema, { summary: { current_value: '1.00' } }, 'GET /summary'),
    ).toThrow(SchemaValidationError)
  })

  // --- Export / import (#64) ---

  it('parses the WRAPPED import report with its per-portfolio rows', () => {
    const payload = {
      import: {
        format: 'wealthsimple.holdings',
        dry_run: false,
        totals: {
          portfolios_created: 2,
          portfolios_skipped: 0,
          portfolios_failed: 1,
          transactions_created: 11,
          recurring_created: 0,
        },
        warnings: ['A holdings report has no trade history…'],
        portfolios: [
          {
            name: 'TFSA',
            imported_as: 'TFSA (imported)',
            status: 'renamed',
            transactions_created: 8,
            recurring_created: 0,
            errors: [],
            warnings: ['A portfolio named “TFSA” already exists…'],
          },
          {
            name: 'Bad',
            imported_as: null,
            status: 'failed',
            transactions_created: 0,
            recurring_created: 0,
            errors: ['Transaction 2 (sell AAPL on 2024-02-05) could not be imported: …'],
            warnings: [],
          },
        ],
      },
    }

    const parsed = parseResponse(importResponseSchema, payload, 'POST /portfolios/import')

    expect(parsed.import.totals.portfolios_failed).toBe(1)
    expect(parsed.import.portfolios[0].imported_as).toBe('TFSA (imported)')
    expect(parsed.import.portfolios[1].imported_as).toBeNull()
    expect(parsed.import.portfolios[1].errors).toHaveLength(1)
  })

  it('accepts a status this build does not know rather than blanking the dialog', () => {
    // `status` is deliberately z.string(), not z.enum: in dev a schema failure
    // THROWS, so enumerating statuses would turn a newer backend into a broken
    // import dialog instead of a slightly-generic label.
    const parsed = importReportSchema.parse({
      format: 'portfolioview.portfolios',
      dry_run: true,
      totals: {
        portfolios_created: 0,
        portfolios_skipped: 0,
        portfolios_failed: 0,
        transactions_created: 0,
        recurring_created: 0,
      },
      warnings: [],
      portfolios: [
        {
          name: 'X',
          imported_as: null,
          status: 'quarantined',
          transactions_created: 0,
          recurring_created: 0,
          errors: [],
          warnings: [],
        },
      ],
    })

    expect(parsed.portfolios[0].status).toBe('quarantined')
  })

  it('labels both import formats and passes an unknown one through', () => {
    expect(formatLabel(NATIVE_FORMAT)).toBe('PortfolioView export')
    expect(formatLabel(HOLDINGS_CSV_FORMAT)).toBe('Broker holdings report')
    expect(formatLabel('something.new')).toBe('something.new')
  })

  it('keeps the client-side upload cap in step with the server', () => {
    // Portfolios::Transfer::MAX_FILE_BYTES
    expect(MAX_IMPORT_BYTES).toBe(8 * 1024 * 1024)
  })
})
