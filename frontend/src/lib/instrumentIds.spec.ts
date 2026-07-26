import { describe, expect, it } from 'vitest'
import { buildInstrumentIdMap, resolveInstrumentId } from './instrumentIds'
import type { Allocations, Transaction } from '@/types'

function transaction(overrides: Partial<Transaction> = {}): Transaction {
  return {
    id: 1,
    portfolio_id: 1,
    instrument_id: 10,
    symbol: 'AAPL',
    side: 'buy',
    kind: 'normal',
    shares: '10.0',
    price: '150.0',
    fees: '0.0',
    executed_on: '2026-07-24',
    notes: null,
    recurring_transaction_id: null,
    created_at: '2026-07-24T12:00:00Z',
    updated_at: '2026-07-24T12:00:00Z',
    ...overrides,
  }
}

/**
 * `sector` is irrelevant to symbol -> id resolution, so rows may omit it and get
 * a filler label; that keeps these cases about the nullable `symbol` they exist
 * to pin.
 */
type PartialSlice = Omit<Allocations['by_instrument'][number], 'sector'> & { sector?: string }

function allocations(byInstrument: PartialSlice[]): Allocations {
  return {
    as_of: '2026-07-24',
    total_value: '1000.0',
    by_instrument: byInstrument.map((row) => ({ sector: 'Technology', ...row })),
    by_sector: [],
  }
}

describe('buildInstrumentIdMap', () => {
  it('maps each traded symbol to its instrument_id', () => {
    const map = buildInstrumentIdMap([
      transaction({ symbol: 'AAPL', instrument_id: 10 }),
      transaction({ id: 2, symbol: 'MSFT', instrument_id: 11 }),
    ])

    expect(resolveInstrumentId(map, 'AAPL')).toBe(10)
    expect(resolveInstrumentId(map, 'MSFT')).toBe(11)
  })

  it('also picks up currently-held instruments from allocations', () => {
    // Covers a holding whose transactions sit on another page of the list.
    const map = buildInstrumentIdMap(
      [],
      allocations([{ instrument_id: 42, symbol: 'SPY', value: '500.0', weight: '0.5' }]),
    )

    expect(resolveInstrumentId(map, 'SPY')).toBe(42)
  })

  it('lets transactions win over allocations on conflict', () => {
    // Transactions are the authoritative record of what was traded; an
    // allocation row's symbol is nullable per the API contract.
    const map = buildInstrumentIdMap(
      [transaction({ symbol: 'AAPL', instrument_id: 10 })],
      allocations([{ instrument_id: 999, symbol: 'AAPL', value: '1.0', weight: '1.0' }]),
    )

    expect(resolveInstrumentId(map, 'AAPL')).toBe(10)
  })

  it('skips allocation rows with a null symbol rather than keying on null', () => {
    const map = buildInstrumentIdMap(
      [],
      allocations([
        { instrument_id: 7, symbol: null, value: '1.0', weight: '0.5' },
        { instrument_id: 8, symbol: 'QQQ', value: '1.0', weight: '0.5' },
      ]),
    )

    expect(map.size).toBe(1)
    expect(resolveInstrumentId(map, 'QQQ')).toBe(8)
  })

  it('is empty for a portfolio with no history', () => {
    expect(buildInstrumentIdMap().size).toBe(0)
    expect(buildInstrumentIdMap([], null).size).toBe(0)
  })
})

describe('resolveInstrumentId', () => {
  const map = buildInstrumentIdMap([transaction({ symbol: 'AAPL', instrument_id: 10 })])

  it('matches case-insensitively and ignores surrounding whitespace', () => {
    expect(resolveInstrumentId(map, 'aapl')).toBe(10)
    expect(resolveInstrumentId(map, 'AaPl')).toBe(10)
    expect(resolveInstrumentId(map, '  AAPL  ')).toBe(10)
  })

  it('returns null for a symbol this portfolio has never traded', () => {
    // The documented consequence: the drawer then leaves price empty rather than
    // addressing /instruments/:id/price with an id it does not have.
    expect(resolveInstrumentId(map, 'TSLA')).toBeNull()
  })

  it('returns null for empty or missing input', () => {
    expect(resolveInstrumentId(map, '')).toBeNull()
    expect(resolveInstrumentId(map, null)).toBeNull()
    expect(resolveInstrumentId(map, undefined)).toBeNull()
  })
})
