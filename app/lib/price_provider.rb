# PriceProvider is the infrastructure boundary to the external market-data
# APIs (docs/PLAN.md § Free data sources / § Price pipeline):
#
#   Tiingo     - primary: raw unadjusted EOD OHLCV + splitFactor + divCash
#   TwelveData - fallback: FORWARD-DELTA-ONLY, adjust=none, never splits/backfill
#   Fmp        - metadata: sector/industry profile, one-time per ticker
#
# Adapters are plain POROs over Faraday. They return frozen value objects and
# raise the typed errors below; they never write to the database and never
# log or embed API keys in messages. All prices/shares are BigDecimal - the
# JSON bodies are parsed with `decimal_class: BigDecimal` so a Float can
# never sneak into money math.
module PriceProvider
  # All provider date logic (budget windows, delta guards) runs in
  # America/New_York, like every other date decision in the app.
  TIME_ZONE = "America/New_York"

  # --- Typed errors -----------------------------------------------------
  # The retry/discard policies of the price-pipeline jobs (M2 follow-ups)
  # key off these classes; do not collapse them into a generic error.

  class Error < StandardError; end

  # Missing/rejected API key. Not retryable.
  class ConfigurationError < Error; end

  # HTTP 429 or an exhausted local budget counter. `retry_after` is the
  # number of seconds a job should wait before retrying.
  class RateLimited < Error
    attr_reader :retry_after

    def initialize(message = "rate limited", retry_after: nil)
      @retry_after = retry_after
      super(message)
    end
  end

  # A local budget/pacing counter tripped before an HTTP call was made: the
  # per-provider daily request budget, the Tiingo hourly pacing window, or the
  # Tiingo monthly unique-symbol quota (see PriceProvider::Budget). It is a
  # RateLimited so jobs that already back off on `retry_after` handle it
  # uniformly, but a distinct subclass so it can be told apart in metrics/logs.
  class BudgetExceeded < RateLimited; end

  # Transient provider failure (5xx, network error). Retryable with backoff.
  class ServerError < Error; end

  # The provider does not know the symbol. Not retryable.
  class UnknownSymbol < Error; end

  # 2xx response whose body is not the documented shape. Never a silent nil.
  class MalformedResponse < Error; end

  # Raised when a caller asks a forward-delta-only adapter (TwelveData) for
  # anything that amounts to a backfill. Deliberate, load-bearing refusal:
  # see docs/PLAN.md § Free data sources.
  class BackfillNotSupported < Error; end

  # --- Value objects (the adapter contract) -----------------------------
  # Data instances are frozen; collections inside DailySeries are frozen too.

  # One raw, unadjusted EOD row. open/high/low/close are BigDecimal.
  Bar = Data.define(:date, :open, :high, :low, :close, :volume)

  # A split event: `ratio` is the provider's decimal factor (4.0 for 4:1),
  # stored as-is per the plan (no integer rationalizing of 10:9 oddities).
  Split = Data.define(:ex_date, :ratio)

  # A cash dividend. Only emitted when cash_per_share > 0 (the DB CHECK on
  # dividend_events requires it; divCash == 0 rows are not events).
  Dividend = Data.define(:ex_date, :cash_per_share)

  # The result of a daily-series fetch. `warnings` lists provider rows that
  # were validated and skipped before reaching the caller (bad OHLC etc.),
  # per the plan's "validate and skip before the batch upsert".
  DailySeries = Data.define(:symbol, :bars, :splits, :dividends, :warnings) do
    def empty? = bars.empty?
  end

  # Company metadata from FMP's /stable/profile (sector/industry lookup). A
  # not-found lookup is an explicit result, never an exception: metadata is
  # best-effort and a missing profile must not break instrument creation.
  # `instrument_type` is "etf" or "stock"; ETFs have no free-tier sector and
  # are bucketed as "ETF / Fund" downstream, so `sector` is nil for them.
  Profile = Data.define(:symbol, :name, :sector, :industry, :instrument_type, :found) do
    def self.not_found(symbol)
      new(symbol:, name: nil, sector: nil, industry: nil, instrument_type: nil, found: false)
    end

    def found? = found
  end
end
