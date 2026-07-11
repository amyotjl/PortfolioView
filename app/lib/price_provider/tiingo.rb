module PriceProvider
  # Tiingo EOD adapter - the primary price provider (docs/PLAN.md § Free
  # data sources). Its /tiingo/daily/<symbol>/prices endpoint returns RAW
  # UNADJUSTED OHLCV plus `splitFactor` and `divCash` per row, which is
  # exactly what the split-correct storage model needs: prices are stored
  # unadjusted, splits are events, share counts roll forward at read time.
  #
  # Free-tier quotas (1,000 req/day, 50/hr, 500 unique symbols/month) are
  # enforced by PriceProvider::Budget in the calling jobs, not here.
  class Tiingo < Base
    API_KEY_ENV = "TIINGO_API_KEY"
    BASE_URL = "https://api.tiingo.com"

    # A full-history backfill MUST pass an explicit startDate: without one
    # Tiingo returns a truncated recent window, not the full 30+ years.
    EARLIEST_START = Date.new(1900, 1, 1)

    # Fetches raw EOD rows for `symbol` over [from, to] (to defaults to
    # "through today" on Tiingo's side). Returns a frozen DailySeries with
    # bars ascending by date, split events (splitFactor != 1) and dividend
    # events (divCash > 0 only - a divCash of 0 is not an event).
    def fetch_daily(symbol, from:, to: nil)
      sym = normalize_symbol(symbol)
      params = { startDate: from.to_date.iso8601, format: "json" }
      params[:endDate] = to.to_date.iso8601 if to
      rows = get_json("/tiingo/daily/#{sym}/prices", params)
      unless rows.is_a?(Array)
        raise MalformedResponse, "#{provider_name}: expected an array of EOD rows for #{sym}"
      end
      build_series(sym, rows)
    end

    # Full-history backfill: one call with explicit startDate=1900-01-01.
    def fetch_full_history(symbol, to: nil)
      fetch_daily(symbol, from: EARLIEST_START, to: to)
    end

    private

    # Tiingo auth goes in a header so the key never appears in any URL.
    def default_headers = super.merge("Authorization" => "Token #{api_key}")

    def build_series(sym, rows)
      bars = []
      splits = []
      dividends = []
      warnings = []

      rows.each do |row|
        date = parse_date(row["date"])
        open, high, low, close = %w[open high low close].map { |k| to_decimal(row[k]) }

        # Validate-and-skip before the caller ever sees the row: a corrupt
        # row's event fields (splitFactor/divCash) are not trusted either.
        unless date && valid_ohlc?(open, high, low, close)
          warnings << skip_warning(sym, "skipped bad EOD row date=#{row['date'].inspect} " \
            "open=#{row['open'].inspect} high=#{row['high'].inspect} " \
            "low=#{row['low'].inspect} close=#{row['close'].inspect}")
          next
        end

        bars << Bar.new(date:, open:, high:, low:, close:, volume: row["volume"].to_i)

        ratio = to_decimal(row["splitFactor"])
        if ratio && ratio != 1
          if ratio.positive?
            splits << Split.new(ex_date: date, ratio:)
          else
            warnings << skip_warning(sym, "skipped non-positive splitFactor #{row['splitFactor'].inspect} on #{date}")
          end
        end

        div = to_decimal(row["divCash"])
        if div&.positive?
          dividends << Dividend.new(ex_date: date, cash_per_share: div)
        elsif div&.negative?
          warnings << skip_warning(sym, "skipped negative divCash #{row['divCash'].inspect} on #{date}")
        end
      end

      DailySeries.new(symbol: sym,
                      bars: bars.sort_by!(&:date).freeze,
                      splits: splits.freeze,
                      dividends: dividends.freeze,
                      warnings: warnings.freeze)
    end
  end
end
