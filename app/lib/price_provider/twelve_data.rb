module PriceProvider
  # Twelve Data adapter — the FALLBACK price provider, and a deliberately
  # crippled one (docs/PLAN.md § Free data sources).
  #
  # Twelve Data's free time series are SPLIT-ADJUSTED and it exposes no free
  # split events, so this adapter is FORWARD-DELTA-ONLY:
  #
  #   * every request pins `adjust=none`;
  #   * the only public fetch requires a since-date — there is intentionally
  #     NO full-history / backfill method. Asking for one raises
  #     BackfillNotSupported;
  #   * it NEVER returns split or dividend events (the returned DailySeries
  #     always has empty `splits` and `dividends`).
  #
  # Why so restrictive: a fallback backfill would silently mix adjusted and
  # raw price bases and corrupt valuations by the split factor (e.g. 4x across
  # a 4:1 split). This adapter exists only to patch a few recent EOD rows when
  # Tiingo is briefly unavailable; the daily-sync overlap check (M2 jobs) still
  # guards against basis drift on the rows it does return.
  class TwelveData < Base
    API_KEY_ENV = "TWELVE_DATA_API_KEY"
    BASE_URL = "https://api.twelvedata.com"

    # Split adjustment is refused at the wire level, on every request.
    ADJUST = "none"
    INTERVAL = "1day"
    # Twelve Data caps a single response at 5000 rows; a forward delta is only
    # ever a handful of days, so this is just a safe ceiling.
    MAX_OUTPUTSIZE = 5000

    # Fetch raw daily bars for `symbol` from `since` (inclusive) forward. The
    # since-date is mandatory: this adapter cannot and must not backfill.
    # Returns a frozen DailySeries whose `splits` and `dividends` are ALWAYS
    # empty by design (see the class comment).
    def fetch_delta(symbol, since:, to: nil)
      start_date = require_since!(since)
      sym = normalize_symbol(symbol)

      params = {
        symbol: sym,
        interval: INTERVAL,
        adjust: ADJUST,            # load-bearing: never adjusted
        order: "ASC",
        outputsize: MAX_OUTPUTSIZE,
        format: "JSON",
        start_date: start_date.iso8601
      }
      params[:end_date] = coerce_date(to).iso8601 if to

      body = get_json("/time_series", params)
      build_series(sym, body)
    end

    # --- REFERENCE data (issue #66) -------------------------------------------
    #
    # A deliberate exception to this class's forward-delta-only rule, and the
    # exception is safe because it returns NO PRICES. /stocks and /etf are
    # symbol directories, and on the FREE tier they cover markets whose price
    # series are paywalled — Canada included: 5,500 stocks and 3,686 ETFs
    # across XTSE / XTSX / NEOE / XCNQ, each carrying a NAME, which Tiingo's
    # bulk file has never had for anything.
    #
    # That is what makes Canadian autocomplete possible without a live provider
    # call from the ticker box: the local directory gains the rows, and
    # ListedInstrument.search keeps working exactly as it does for US symbols.
    # Prices for those same symbols still come from Yahoo (Prices::ProviderRouter)
    # because Twelve Data 403s their time series on this tier.
    #
    # Returns an array of plain hashes; the caller maps them onto
    # listed_instruments. Paging is not used: both endpoints return the full
    # country list in one response.
    def fetch_country_listings(country:, kind:)
      unless %w[stocks etf].include?(kind.to_s)
        raise ArgumentError, "kind must be stocks or etf, got #{kind.inspect}"
      end

      body = get_json("/#{kind}", country: country)
      rows = body.is_a?(Hash) ? body["data"] : nil
      unless rows.is_a?(Array)
        raise MalformedResponse, "#{provider_name}: expected a data array from /#{kind}"
      end

      rows
    end

    private

    # Auth travels in the Authorization header (not the URL) so the key never
    # lands in a query string that might get logged upstream.
    def default_headers = super.merge("Authorization" => "apikey #{api_key}")

    def require_since!(since)
      if since.nil? || (since.respond_to?(:empty?) && since.empty?)
        raise BackfillNotSupported,
              "TwelveData is forward-delta-only: a since-date is required (no backfill/full-history fetch)."
      end
      coerce_date(since)
    end

    def coerce_date(value)
      return value.to_date if value.respond_to?(:to_date)
      Date.iso8601(value.to_s)
    rescue ArgumentError, TypeError
      raise ArgumentError, "invalid date #{value.inspect}"
    end

    def build_series(sym, body)
      unless body.is_a?(Hash)
        raise MalformedResponse, "#{provider_name}: expected an object for #{sym}"
      end

      # Twelve Data reports most failures as an HTTP 200 with an error object
      # ({ "status" => "error", "code" => ..., "message" => ... }) rather than
      # a non-2xx status, so Base#handle_status! can't catch them — map here.
      if body["status"] == "error" || body.key?("code")
        return handle_body_error(sym, body)
      end

      values = body["values"]
      # A successful-but-empty range still returns status "ok" with values: [].
      values = [] if values.nil?
      unless values.is_a?(Array)
        raise MalformedResponse, "#{provider_name}: expected a values array for #{sym}"
      end

      bars = []
      warnings = []
      values.each do |row|
        date = parse_date(row["datetime"])
        open, high, low, close = %w[open high low close].map { |k| to_decimal(row[k]) }

        unless date && valid_ohlc?(open, high, low, close)
          warnings << skip_warning(sym, "skipped bad delta row datetime=#{row['datetime'].inspect} " \
            "open=#{row['open'].inspect} high=#{row['high'].inspect} " \
            "low=#{row['low'].inspect} close=#{row['close'].inspect}")
          next
        end

        bars << Bar.new(date:, open:, high:, low:, close:, volume: row["volume"].to_i)
      end

      # splits/dividends are ALWAYS empty — this adapter must never ingest them.
      DailySeries.new(symbol: sym,
                      bars: bars.sort_by!(&:date).freeze,
                      splits: [].freeze,
                      dividends: [].freeze,
                      warnings: warnings.freeze)
    end

    # Maps a Twelve Data error object onto the shared typed errors. A "no data
    # available" 400 is a legitimate empty forward delta, not a failure.
    def handle_body_error(sym, body)
      code = body["code"].to_i
      message = body["message"].to_s

      case code
      when 401, 403
        raise ConfigurationError, "#{provider_name}: credentials rejected (code #{code})"
      when 404
        raise UnknownSymbol, "#{provider_name}: symbol not found (#{sym})"
      when 429
        raise RateLimited.new("#{provider_name}: rate limited (code 429)",
                              retry_after: DEFAULT_RETRY_AFTER)
      when 500..599
        raise ServerError, "#{provider_name}: server error (code #{code}) for #{sym}"
      when 400
        if /no data/i.match?(message)
          return empty_series(sym)
        elsif /not found|invalid symbol/i.match?(message)
          raise UnknownSymbol, "#{provider_name}: symbol not found (#{sym})"
        end
        raise MalformedResponse, "#{provider_name}: bad request (code 400) for #{sym}"
      else
        raise Error, "#{provider_name}: error response (code #{code}) for #{sym}"
      end
    end

    def empty_series(sym)
      DailySeries.new(symbol: sym, bars: [].freeze, splits: [].freeze,
                      dividends: [].freeze, warnings: [].freeze)
    end
  end
end
