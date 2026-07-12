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
  # FAILOVER (docs/PLAN.md § Price pipeline failover rule): if the Tiingo delta
  # fetch fails or its budget is exhausted, the delta window ONLY is refetched
  # from TwelveData with adjust=none. That path records source="twelve_data" and
  # NEVER writes split/dividend events — a fallback that mixed split-adjusted
  # and raw bases would corrupt valuations. An unknown symbol never fails over.
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
    TIINGO = "tiingo".freeze
    TWELVE_DATA = "twelve_data".freeze

    def perform(instrument_id)
      instrument = Instrument.find(instrument_id)

      unless instrument.prices_backfilled_at && instrument.latest_price_on
        # No anchor for a delta fetch yet — hand off to the first-reference backfill.
        Prices::BackfillInstrumentJob.perform_later(instrument.id)
        return
      end

      series, source = fetch_delta_with_failover(instrument)

      if basis_drift?(instrument, series)
        report_basis_drift(instrument, series)
        return
      end

      # write_events only on the primary path — the failover must never ingest
      # split/dividend events (§ failover rule).
      result = Prices::SeriesWriter.call(instrument:, series:, source:, write_events: source == TIINGO)
      # A late-discovered historical split invalidates cached charts (§ Caching).
      bump_series_version(instrument) if result.splits_written.positive?
    rescue PriceProvider::RateLimited => e
      # Both providers exhausted/limited (BudgetExceeded is a RateLimited):
      # reschedule honoring retry_after.
      reschedule_on_rate_limit(e)
    end

    private

    # Returns [series, source]. Tries Tiingo (raw + events); on a transient/
    # budget failure fails over to TwelveData for the delta window only. An
    # UnknownSymbol/ConfigurationError never fails over (it is terminal
    # everywhere) — it propagates to discard_on.
    def fetch_delta_with_failover(instrument)
      from = instrument.latest_price_on
      budget = PriceProvider::Budget.new(TIINGO)
      budget.charge!
      # INCLUSIVE of latest_price_on — the returned overlap row is the drift probe.
      [ tiingo.fetch_daily(instrument.symbol, from: from), TIINGO ]
    rescue PriceProvider::UnknownSymbol, PriceProvider::ConfigurationError
      raise
    rescue PriceProvider::RateLimited, PriceProvider::ServerError => e
      Rails.logger.warn("[#{self.class.name}] Tiingo delta failed for #{instrument.symbol} " \
        "(#{e.class.name.demodulize}); failing over to TwelveData (forward delta only)")
      failover_via_twelve_data(instrument, since: from)
    end

    def failover_via_twelve_data(instrument, since:)
      PriceProvider::Budget.new(TWELVE_DATA).charge!
      # adjust=none, no events — the TwelveData adapter enforces both.
      [ twelve_data.fetch_delta(instrument.symbol, since: since), TWELVE_DATA ]
    end

    def tiingo = PriceProvider::Tiingo.new
    def twelve_data = PriceProvider::TwelveData.new

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
