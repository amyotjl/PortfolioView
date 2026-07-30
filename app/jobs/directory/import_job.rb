require "zip"
require "csv"
require "stringio"

module Directory
  # Weekly import of Tiingo's free supported_tickers bulk file into
  # listed_instruments (docs/PLAN.md § Free data sources), so ticker
  # autocomplete and symbol validation never burn the 500-unique-symbols/month
  # API quota. The file is a ZIP wrapping one CSV
  # (ticker,exchange,assetType,priceCurrency,startDate,endDate).
  #
  # The import is idempotent (upsert_all on the (symbol, exchange) conflict
  # target), malformed rows are skipped and counted rather than failing the run,
  # and a SANITY GUARD aborts the whole import if the file yields implausibly few
  # rows — a truncated/corrupt download must never wipe the existing directory.
  class ImportJob < ApplicationJob
    queue_as :default

    SUPPORTED_TICKERS_URL = "https://apimedia.tiingo.com/docs/tiingo/daily/supported_tickers.zip".freeze

    # Tiingo lists tens of thousands of symbols; a healthy file has far more than
    # this. Anything smaller is treated as a bad download and aborts.
    MIN_EXPECTED_ROWS = 1_000

    # Chunk upsert_all so a full directory stays well under Postgres' bind-param
    # ceiling (5 columns/row).
    BATCH_SIZE = 5_000

    MAX_SYMBOL_LENGTH = 32

    # The default upsert overwrites EVERY non-key column, which would wipe an
    # enriched name back to NULL on each weekly run — every row this file
    # carries has `name: nil`, because Tiingo's bulk file has no name column
    # (issue #63). COALESCE(EXCLUDED.name, …) keeps the incoming value
    # authoritative if a future source ever supplies one, and otherwise
    # preserves what EnrichNamesJob wrote.
    #
    # `symbol`/`exchange` are the conflict target, so they are deliberately not
    # in the SET list. `updated_at` is set explicitly because `on_duplicate:`
    # replaces the clause `record_timestamps:` would have generated (that option
    # still governs the INSERT path, which needs `created_at`).
    PRESERVE_ENRICHED_NAME = Arel.sql(<<~SQL.squish).freeze
      name = COALESCE(EXCLUDED.name, listed_instruments.name),
      asset_type = EXCLUDED.asset_type,
      currency = EXCLUDED.currency,
      updated_at = CURRENT_TIMESTAMP
    SQL

    # `zip_data` and `min_rows` are injectable for tests; the scheduled run uses
    # the defaults (download + the production threshold).
    def perform(min_rows: MIN_EXPECTED_ROWS, zip_data: nil)
      zip_data ||= download
      rows = parse(zip_data)

      if rows.size < min_rows
        Rails.logger.error("[#{self.class.name}] only #{rows.size} valid rows (< #{min_rows}); " \
          "aborting import and keeping the existing directory intact")
        return { imported: 0, aborted: true }
      end

      rows.each_slice(BATCH_SIZE) do |batch|
        ListedInstrument.upsert_all(batch, unique_by: %i[symbol exchange],
                                    record_timestamps: true, on_duplicate: PRESERVE_ENRICHED_NAME)
      end
      Rails.logger.info("[#{self.class.name}] imported #{rows.size} listed instruments")

      # Re-apply names the directory itself cannot supply. Cheap, quota-free,
      # and it makes the pair self-healing: even if a future bulk source starts
      # carrying names, whichever is present wins and nothing is lost.
      EnrichNamesJob.perform_later

      { imported: rows.size, aborted: false }
    end

    private

    def download
      response = Faraday.new { |f| f.adapter Faraday.default_adapter }.get(SUPPORTED_TICKERS_URL)
      unless response.success?
        raise PriceProvider::ServerError, "supported_tickers download failed (HTTP #{response.status})"
      end
      response.body
    end

    # Returns deduped, validated attribute hashes. Malformed rows are skipped and
    # counted; duplicate (symbol, exchange) rows collapse (last wins) so a single
    # upsert batch never conflicts with itself.
    def parse(zip_data)
      csv_text = read_csv(zip_data)
      deduped = {}
      skipped = 0

      CSV.parse(csv_text, headers: true) do |row|
        attrs = row_attributes(row)
        if attrs
          deduped[[ attrs[:symbol], attrs[:exchange] ]] = attrs
        else
          skipped += 1
        end
      end

      Rails.logger.info("[#{self.class.name}] parsed #{deduped.size} unique rows, skipped #{skipped} malformed")
      deduped.values
    end

    def read_csv(zip_data)
      Zip::File.open_buffer(StringIO.new(zip_data.to_s)) do |zip|
        entry = zip.glob("*.csv").first || zip.entries.find { |e| e.name.to_s.downcase.end_with?(".csv") }
        raise PriceProvider::MalformedResponse, "no CSV entry in supported_tickers zip" unless entry
        return entry.get_input_stream.read
      end
    end

    def row_attributes(row)
      symbol = row["ticker"].to_s.strip.upcase
      return nil if symbol.empty? || symbol.length > MAX_SYMBOL_LENGTH

      {
        symbol: symbol,
        name: nil, # Tiingo's bulk file carries no company name
        exchange: row["exchange"].to_s.strip.presence,
        asset_type: row["assetType"].to_s.strip.presence,
        currency: row["priceCurrency"].to_s.strip.presence
      }
    rescue StandardError
      # A row so malformed that even field access raises is skipped, not fatal.
      nil
    end
  end
end
