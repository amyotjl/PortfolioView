module Directory
  # Populates `listed_instruments` with CANADIAN listings (issue #66), which
  # Tiingo's bulk file has never contained — verified: 99,043 USD / 7,154 CNY /
  # 52 HKD / 4 AUD of 106,253 rows, and no TSX/TSXV/CSE/CBOE-Canada venue at
  # all. Without these rows a Canadian ticker cannot be typed, cannot be
  # autocompleted, and cannot be validated; import was the only way in.
  #
  # SOURCE: Twelve Data's /stocks and /etf REFERENCE endpoints, which are free
  # on the Basic tier even for markets whose price SERIES are paywalled. That
  # split is the whole trick — reference data from Twelve Data, prices from
  # Yahoo (Prices::ProviderRouter) — and it means the ticker box still makes no
  # provider call and burns no quota, because search keeps reading the local
  # directory exactly as it does for US symbols.
  #
  # SYMBOLS ARE STORED VENUE-SUFFIXED (`ZEQT.TO`, `FINN.NE`), produced by the
  # same Portfolios::Transfer::SymbolQualifier the importer uses. This is not
  # cosmetic: `instruments` is UNIQUE on upper(symbol) alone, so an unsuffixed
  # Canadian `META` would collide with NASDAQ `META` — a CAD-hedged CDR bound
  # to a US security's price history. The suffix is also exactly what Yahoo
  # expects, so the stored symbol is the one that fetches.
  class ImportCanadianJob < ApplicationJob
    queue_as :default

    COUNTRY = "Canada".freeze
    KINDS = %w[stocks etf].freeze

    # Sanity guard, mirroring Directory::ImportJob's: a truncated or errored
    # response must never be treated as "Canada now has 12 listings". Measured
    # 2026-08-03: 5,500 stocks + 3,686 ETFs.
    MIN_EXPECTED_ROWS = 500

    BATCH_SIZE = 5_000
    MAX_SYMBOL_LENGTH = 32

    # Same COALESCE posture as the Tiingo import: never let a re-import wipe a
    # name. Here the incoming rows DO carry names, so EXCLUDED usually wins —
    # but an enriched name must still survive a response that happens to omit
    # one.
    PRESERVE_ENRICHED_NAME = Arel.sql(<<~SQL.squish).freeze
      name = COALESCE(EXCLUDED.name, listed_instruments.name),
      asset_type = EXCLUDED.asset_type,
      currency = EXCLUDED.currency,
      updated_at = CURRENT_TIMESTAMP
    SQL

    def perform(min_rows: MIN_EXPECTED_ROWS, provider: nil)
      provider ||= PriceProvider::TwelveData.new
      rows = KINDS.flat_map { |kind| fetch(provider, kind) }
      deduped = dedupe(rows)

      if deduped.size < min_rows
        Rails.logger.error("[#{self.class.name}] only #{deduped.size} valid rows (< #{min_rows}); " \
          "aborting and keeping the existing directory intact")
        return { imported: 0, aborted: true }
      end

      deduped.each_slice(BATCH_SIZE) do |batch|
        ListedInstrument.upsert_all(batch, unique_by: %i[symbol exchange],
                                    record_timestamps: true, on_duplicate: PRESERVE_ENRICHED_NAME)
      end
      Rails.logger.info("[#{self.class.name}] imported #{deduped.size} Canadian listings")
      { imported: deduped.size, aborted: false }
    end

    private

    def fetch(provider, kind)
      provider.fetch_country_listings(country: COUNTRY, kind: kind).filter_map do |row|
        row_attributes(row, kind)
      end
    rescue PriceProvider::Error => e
      # One kind failing must not lose the other. A partial import is still a
      # net gain, and the sanity guard above still refuses an implausible total.
      Rails.logger.warn("[#{self.class.name}] /#{kind} failed (#{e.class.name.demodulize}); skipping")
      []
    end

    def row_attributes(row, kind)
      raw = row["symbol"].to_s.strip.upcase
      mic = row["mic_code"].to_s.strip.upcase
      return nil if raw.empty?

      # SymbolQualifier owns the MIC -> suffix map; an unmapped MIC returns the
      # bare symbol, which would collide with a US ticker, so it is skipped
      # rather than stored ambiguously.
      symbol = Portfolios::Transfer::SymbolQualifier.call(symbol: raw, mic: mic,
                                                          currency: row["currency"])
      return nil if symbol == raw || symbol.length > MAX_SYMBOL_LENGTH

      {
        symbol: symbol,
        name: row["name"].to_s.strip.presence,
        exchange: row["exchange"].to_s.strip.presence,
        asset_type: asset_type_for(row, kind),
        currency: row["currency"].to_s.strip.presence
      }
    rescue StandardError
      nil
    end

    # The /etf endpoint carries no `type`, so the endpoint itself is the signal.
    # "ETF" matches the string DirectoryResolver already tests for when deciding
    # instrument_type, and the value Tiingo's file uses.
    def asset_type_for(row, kind)
      return "ETF" if kind == "etf"

      row["type"].to_s.strip.presence
    end

    # The same (symbol, exchange) pair can appear twice in one response; a
    # single upsert batch must never conflict with itself.
    def dedupe(rows)
      rows.index_by { |r| [ r[:symbol], r[:exchange] ] }.values
    end
  end
end
