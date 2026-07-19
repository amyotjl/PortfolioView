import { describe, expect, it } from 'vitest'
import {
  allocationsResponseSchema,
  candlesResponseSchema,
  errorEnvelopeSchema,
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
})
