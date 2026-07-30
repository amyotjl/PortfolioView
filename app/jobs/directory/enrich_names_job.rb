module Directory
  # Copies company names from `instruments` into `listed_instruments` (issue
  # #63), so ticker autocomplete can show "MSFT — Microsoft Corporation"
  # instead of a bare ticker.
  #
  # WHY THIS SOURCE: Tiingo's supported_tickers bulk file — the only thing that
  # populates the directory — has no company-name column at all, so all 106,253
  # rows ship with `name: nil`. But `instruments.name` is already filled by
  # Instruments::MetadataJob from the FMP profile for every symbol the user has
  # actually touched. Reading it back costs **zero provider quota** and no HTTP:
  # it is data this app already paid for. Coverage is therefore deliberately
  # partial — it grows as the user's portfolio does, which is exactly the set of
  # symbols whose names are worth showing.
  #
  # MATCHING IS ASSET-CLASS AWARE, not symbol-only. One ticker can name two
  # different securities across venues (the real directory has MSFC as a NASDAQ
  # *Stock* and a BATS *ETF*), and `instruments` is UNIQUE on upper(symbol)
  # alone, so a symbol-only join would happily label an unrelated ETF with an
  # equity's company name. Pairing the instrument's `instrument_type`
  # (stock/etf) with the directory row's `asset_type` keeps a name on the row it
  # actually describes; the same stock/etf mapping DirectoryResolver already
  # uses, read in the opposite direction.
  #
  # Only tradeable rows are touched. A row that DirectoryResolver would reject
  # can never be the security the user holds, so enriching it would be guessing.
  class EnrichNamesJob < ApplicationJob
    queue_as :default

    # A single set-based UPDATE ... FROM — the directory is ~106k rows and the
    # instruments side is small, so this is one indexed pass, not an N+1 sweep.
    #
    # `IS DISTINCT FROM` (not `<>`) so NULL names compare correctly and the
    # statement is idempotent: a second run touches zero rows and bumps no
    # timestamps, which is what makes it safe to enqueue after every import.
    SQL = <<~SQL.freeze
      UPDATE listed_instruments li
      SET name = i.name, updated_at = CURRENT_TIMESTAMP
      FROM instruments i
      WHERE upper(li.symbol) = upper(i.symbol)
        AND i.name IS NOT NULL
        AND btrim(i.name) <> ''
        AND upper(li.currency) = 'USD'
        AND upper(btrim(li.exchange)) IN (:us)
        AND CASE WHEN lower(li.asset_type) LIKE '%%etf%%' THEN 'etf' ELSE 'stock' END = i.instrument_type
        AND li.name IS DISTINCT FROM i.name
    SQL

    def perform
      sql = ListedInstrument.sanitize_sql_array([ SQL, { us: ListedInstrument::US_EXCHANGES.to_a } ])
      updated = ListedInstrument.connection.update(sql)
      Rails.logger.info("[#{self.class.name}] enriched #{updated} listed_instruments names")
      { enriched: updated }
    end
  end
end
