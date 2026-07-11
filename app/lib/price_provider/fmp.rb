module PriceProvider
  # Financial Modeling Prep adapter — sector/industry metadata only
  # (docs/PLAN.md § Free data sources). Its /stable/profile endpoint gives a
  # company's sector, industry, name and type on a free 250 req/day tier. This
  # is a one-time lookup per ticker, cached forever in Postgres.
  #
  # Unlike the price adapters, an unknown/missing profile is NOT an error: it
  # returns Profile.not_found so a new instrument can still be created (with no
  # sector — ETFs and unknowns are bucketed as "ETF / Fund" downstream).
  class Fmp < Base
    API_KEY_ENV = "FMP_API_KEY"
    BASE_URL = "https://financialmodelingprep.com"

    # Fetch the company profile for `symbol`. Returns a frozen Profile; a
    # symbol FMP does not recognise yields Profile.not_found(symbol) rather
    # than raising.
    def fetch_profile(symbol)
      sym = normalize_symbol(symbol)
      # FMP authenticates via an `apikey` query param (no header auth). The key
      # rides the (HTTPS) request only and is never logged — Base error
      # messages carry the path, never the query string.
      body = get_json("/stable/profile", symbol: sym, apikey: api_key)
      build_profile(sym, body)
    end

    private

    def build_profile(sym, body)
      row = extract_row(body)
      return Profile.not_found(sym) if row.nil?

      Profile.new(
        symbol: (row["symbol"].presence || sym).to_s.upcase,
        name: row["companyName"].presence,
        sector: row["sector"].presence,
        industry: row["industry"].presence,
        instrument_type: instrument_type_for(row),
        found: true
      )
    end

    # /stable/profile returns an array with zero or one object; an unknown
    # symbol yields []. Be tolerant of a bare object too.
    def extract_row(body)
      case body
      when Array
        first = body.first
        first.is_a?(Hash) ? first : nil
      when Hash
        # A genuine profile object has a symbol; anything else (e.g. an
        # error-shaped hash) is treated as "not found" rather than crashing.
        body.key?("symbol") ? body : nil
      end
    end

    def instrument_type_for(row)
      truthy?(row["isEtf"]) || truthy?(row["isFund"]) ? "etf" : "stock"
    end

    def truthy?(value)
      value == true || value.to_s.strip.downcase == "true"
    end
  end
end
