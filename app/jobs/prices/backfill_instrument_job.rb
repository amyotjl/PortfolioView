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
  #
  # WHICH provider is Prices::ProviderRouter's decision, not this job's — a
  # venue-suffixed symbol goes to Yahoo because Tiingo has no Canadian data at
  # all (issue #66). Both return the same raw-prices-plus-events shape, so the
  # rest of this job is provider-agnostic; only the budget differs, because a
  # keyless provider has no quota to charge.
  class BackfillInstrumentJob < ApplicationJob
    include ProviderErrorHandling

    queue_as :default

    # Serialize per instrument so a backfill and the nightly fetch (or a second
    # backfill) can't race on the same instrument's rows.
    limits_concurrency to: 1, key: ->(instrument_id) { "instrument-prices-#{instrument_id}" }

    def perform(instrument_id)
      instrument = Instrument.find(instrument_id)
      # Tiingo for a US symbol, Yahoo for a venue-suffixed one (issue #66).
      # Tiingo's directory has no Canadian rows at all, so this is not a
      # preference — it is the difference between having history and having none.
      route = Prices::ProviderRouter.for(instrument)

      if route.budgeted?
        budget = PriceProvider::Budget.new(route.budget_name)
        # Charge the scarcer monthly unique-symbol quota first, then the daily/
        # hourly request budget; either raising BudgetExceeded reschedules the job.
        budget.register_symbol!(instrument.symbol)
        budget.charge!
      end

      series = route.provider.fetch_full_history(instrument.symbol)
      Prices::SeriesWriter.call(instrument:, series:, source: route.name, write_events: true)

      instrument.update_columns(prices_backfilled_at: Time.current)
      bump_series_version(instrument)
    rescue PriceProvider::RateLimited => e
      # BudgetExceeded is a RateLimited: both land here and reschedule. The
      # instrument is left un-backfilled (prices_backfilled_at nil).
      reschedule_on_rate_limit(e)
    end

    private

    # series_version bumps on backfill completion (docs/PLAN.md § Caching): any
    # portfolio that trades or has a recurring rule on this instrument.
    def bump_series_version(instrument)
      Portfolio.holding(instrument).update_all("series_version = series_version + 1")
    end
  end
end
