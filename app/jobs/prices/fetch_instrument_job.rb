module Prices
  # The nightly per-instrument delta fetch (docs/PLAN.md § Price pipeline).
  #
  # It starts from `latest_price_on` INCLUSIVE: that one-day overlap row is the
  # drift probe. Each night the fetched overlap-day close is compared to the
  # stored close, and a >20% mismatch flags BASIS DRIFT — the classic signature
  # of a provider silently switching from raw to split-adjusted data — and
  # aborts the write for that instrument rather than corrupting the store. New
  # rows (prices + split + dividend events) are otherwise upserted through the
  # shared SeriesWriter, and a late-discovered historical split bumps the
  # holders' series_version so stale charts don't stay cached.
  #
  # Per-instrument fetches serialize via limits_concurrency so a backfill and a
  # nightly fetch (or two fetches) can't race on the same instrument's rows.
  class FetchInstrumentJob < ApplicationJob
    include ProviderErrorHandling

    queue_as :default
    limits_concurrency to: 1, key: ->(instrument_id) { "instrument-prices-#{instrument_id}" }

    # A same-day close that moves >20% vs. the stored close is treated as a
    # basis change, not a real move (no US equity gaps 20% between the same
    # date's two fetches under a stable basis).
    DRIFT_THRESHOLD = BigDecimal("0.20")
    PROVIDER_NAME = "tiingo".freeze

    def perform(instrument_id)
      instrument = Instrument.find(instrument_id)

      unless instrument.prices_backfilled_at && instrument.latest_price_on
        # No anchor for a delta fetch yet — hand off to the first-reference backfill.
        Prices::BackfillInstrumentJob.perform_later(instrument.id)
        return
      end

      series = fetch_delta(instrument)

      if basis_drift?(instrument, series)
        report_basis_drift(instrument, series)
        return
      end

      result = Prices::SeriesWriter.call(instrument:, series:, source: PROVIDER_NAME, write_events: true)
      # A late-discovered historical split invalidates cached charts (§ Caching).
      bump_series_version(instrument) if result.splits_written.positive?
    rescue PriceProvider::RateLimited => e
      # BudgetExceeded is a RateLimited: both reschedule honoring retry_after.
      reschedule_on_rate_limit(e)
    end

    private

    def fetch_delta(instrument)
      budget = PriceProvider::Budget.new(PROVIDER_NAME)
      budget.charge!
      # INCLUSIVE of latest_price_on — the returned overlap row is the drift probe.
      provider.fetch_daily(instrument.symbol, from: instrument.latest_price_on)
    end

    def provider = PriceProvider::Tiingo.new

    def basis_drift?(instrument, series)
      stored = stored_overlap(instrument)
      fetched = fetched_overlap(instrument, series)
      return false unless stored && fetched && stored.close&.positive?

      ((fetched.close - stored.close).abs / stored.close) > DRIFT_THRESHOLD
    end

    def stored_overlap(instrument)
      instrument.daily_prices.find_by(date: instrument.latest_price_on)
    end

    def fetched_overlap(instrument, series)
      series.bars.find { |bar| bar.date == instrument.latest_price_on }
    end

    def report_basis_drift(instrument, series)
      stored = stored_overlap(instrument)
      fetched = fetched_overlap(instrument, series)
      message = "[#{self.class.name}] basis drift for #{instrument.symbol} on " \
        "#{instrument.latest_price_on}: stored=#{stored&.close} fetched=#{fetched&.close}; " \
        "aborting writes (provider may have switched to adjusted data)"
      Rails.logger.error(message)
      Rails.error.report(RuntimeError.new(message), handled: true,
                         context: { instrument_id: instrument.id, symbol: instrument.symbol })
    end

    def bump_series_version(instrument)
      Portfolio.holding(instrument).update_all("series_version = series_version + 1")
    end
  end
end
