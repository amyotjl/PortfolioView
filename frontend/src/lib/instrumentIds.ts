import type { Allocations, Transaction } from '@/types'

/**
 * Symbol -> instrument_id resolution, built from data the frontend already has.
 *
 * WHY THIS EXISTS. `GET /instruments/search` serves the autocomplete from the
 * `listed_instruments` directory table and returns NO id (docs/API_SHAPES.md).
 * That is not an oversight to work around by adding one: `listed_instruments`
 * and `instruments` are separate tables with independent primary keys, so a
 * directory row's id is meaningless to `/instruments/:id/price` and
 * `?instrument_id=` — passing one would silently address a *different*
 * instrument. Symbols are the only cross-table identity.
 *
 * But `/instruments/:id/price` (price prefill) and `/holdings?instrument_id=`
 * (sell pre-flight) are both id-addressed, so the form needs a symbol -> id map.
 * Both of the portfolio's own payloads carry the pairing already:
 *   - `transactions[].{symbol, instrument_id}`
 *   - `allocations.by_instrument[].{symbol, instrument_id}`
 * so we derive the map from those instead of adding an endpoint.
 *
 * CONSEQUENCE, BY DESIGN: a symbol this portfolio has never traded resolves to
 * null, and the form leaves price empty for the user to type. That is not much
 * of a loss — an `Instrument` row (and its price backfill) only comes into being
 * on first reference, so a genuinely new symbol has no cached close to prefill
 * from either. Sell pre-flight is unaffected: you can only sell what you hold,
 * which means it is always already in the map.
 */

/** Case-insensitive map; directory symbols and user input vary in case. */
export type InstrumentIdMap = ReadonlyMap<string, number>

function normalize(symbol: string): string {
  return symbol.trim().toUpperCase()
}

/**
 * Build the lookup from a portfolio's transactions and (optionally) its current
 * allocations. Allocations are added first so transactions win on conflict —
 * transactions are the authoritative record of what instrument was traded,
 * whereas an allocation row's `symbol` is nullable (docs/API_SHAPES.md).
 */
export function buildInstrumentIdMap(
  transactions: readonly Transaction[] = [],
  allocations: Allocations | null = null,
): InstrumentIdMap {
  const map = new Map<string, number>()

  for (const row of allocations?.by_instrument ?? []) {
    if (row.symbol) map.set(normalize(row.symbol), row.instrument_id)
  }
  for (const tx of transactions) {
    map.set(normalize(tx.symbol), tx.instrument_id)
  }

  return map
}

/** Resolve one symbol, or null when this portfolio has never traded it. */
export function resolveInstrumentId(
  map: InstrumentIdMap,
  symbol: string | null | undefined,
): number | null {
  if (!symbol) return null
  return map.get(normalize(symbol)) ?? null
}
