module Prices
  # First-reference backfill (docs/PLAN.md § Price pipeline): the moment an
  # instrument is created (Instrument#after_create_commit), this pulls its FULL
  # raw history + splits + dividends from Tiingo in ONE call (startDate=1900-01-01)
  # and, on completion, bumps the `series_version` of every portfolio holding it
  # so charts rendered against partial data don't cache stale.
  #
  # It NEVER fails over to TwelveData: a fallback backfill would mix
  # split-adjusted and raw price bases and corrupt valuations, so a backfill
  # failure alerts/retries and leaves the instrument marked un-backfilled
  # (prices_backfilled_at stays nil) rather than reaching for the fallback.
  class BackfillInstrumentJob < ApplicationJob
    include ProviderErrorHandling

    queue_as :default

    # Serialize per instrument so a backfill and the nightly fetch (or a second
    # backfill) can't race on the same instrument's rows.
    limits_concurrency to: 1, key: ->(instrument_id) { "instrument-prices-#{instrument_id}" }

    def perform(instrument_id)
      instrument = Instrument.find(instrument_id)
      budget = PriceProvider::Budget.new("tiingo")

      # Charge the scarcer monthly unique-symbol quota first, then the daily/
      # hourly request budget; either raising BudgetExceeded reschedules the job.
      budget.register_symbol!(instrument.symbol)
      budget.charge!

      series = provider.fetch_full_history(instrument.symbol)
      Prices::SeriesWriter.call(instrument:, series:, source: PROVIDER_NAME, write_events: true)

      instrument.update_columns(prices_backfilled_at: Time.current)
      bump_series_version(instrument)
    rescue PriceProvider::RateLimited => e
      # BudgetExceeded is a RateLimited: both land here and reschedule. The
      # instrument is left un-backfilled (prices_backfilled_at nil).
      reschedule_on_rate_limit(e)
    end

    private

    PROVIDER_NAME = "tiingo".freeze

    def provider = PriceProvider::Tiingo.new

    # series_version bumps on backfill completion (docs/PLAN.md § Caching): any
    # portfolio that trades or has a recurring rule on this instrument.
    def bump_series_version(instrument)
      Portfolio.holding(instrument).update_all("series_version = series_version + 1")
    end
  end
end
