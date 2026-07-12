module Prices
  # Shared, validated batch-writer for a provider DailySeries (docs/PLAN.md
  # § Price pipeline). Both the backfill and the nightly fetch pour their
  # fetched series through here so the "validate and skip before the batch
  # upsert" rule and the split-correct storage model live in exactly one place:
  #
  #   * prices are stored RAW/UNADJUSTED in daily_prices;
  #   * splits/dividends are stored as EVENTS (never applied to prices);
  #   * a row failing the daily_prices CHECK (high >= low AND low > 0, all legs
  #     positive, date present) is skipped so one bad row cannot fail the batch.
  #
  # It advances the instrument's earliest/latest_price_on bounds but is
  # deliberately agnostic about job-completion markers: `prices_backfilled_at`
  # and the portfolios' `series_version` bump are the calling job's business.
  #
  # `write_events: false` is the load-bearing failover guard — the TwelveData
  # fallback path must never write split or dividend events (a fallback that
  # mixed split-adjusted and raw bases would corrupt valuations).
  class SeriesWriter
    # Postgres tops out around 65k bind params per statement; daily_prices has
    # ~9 columns, so 5k rows/batch stays comfortably under the ceiling while
    # keeping a 30-year backfill to a handful of statements.
    BATCH_SIZE = 5_000

    Result = Data.define(
      :prices_written, :prices_skipped,
      :splits_written, :dividends_written,
      :earliest_on, :latest_on
    )

    def self.call(...) = new(...).call

    def initialize(instrument:, series:, source:, write_events: true)
      @instrument = instrument
      @series = series
      @source = source.to_s
      @write_events = write_events
    end

    def call
      valid, skipped = partition_bars
      write_prices(valid)
      splits_written = write_events ? write_splits : 0
      dividends_written = write_events ? write_dividends : 0
      earliest_on, latest_on = advance_bounds(valid)

      Result.new(
        prices_written: valid.size,
        prices_skipped: skipped,
        splits_written: splits_written,
        dividends_written: dividends_written,
        earliest_on: earliest_on,
        latest_on: latest_on
      )
    end

    private

    attr_reader :instrument, :series, :source, :write_events

    # Defense in depth: the adapters already validate, but a bad row must never
    # reach (and poison) the batch upsert regardless of where the series came
    # from. Mirrors the daily_prices CHECK exactly.
    def partition_bars
      valid = series.bars.select { |bar| valid_bar?(bar) }
      [ valid, series.bars.size - valid.size ]
    end

    def valid_bar?(bar)
      bar.date.present? &&
        [ bar.open, bar.high, bar.low, bar.close ].all? { |v| v.is_a?(Numeric) && v.positive? } &&
        bar.high >= bar.low
    end

    def write_prices(bars)
      return if bars.empty?

      bars.each_slice(BATCH_SIZE) do |slice|
        rows = slice.map do |bar|
          {
            instrument_id: instrument.id,
            date: bar.date,
            open: bar.open, high: bar.high, low: bar.low, close: bar.close,
            volume: bar.volume,
            source: source
          }
        end
        DailyPrice.upsert_all(rows, unique_by: %i[instrument_id date], record_timestamps: true)
      end
    end

    # Returns the count of genuinely NEW split ex-dates so the fetch job can
    # bump series_version on a late-discovered historical split.
    def write_splits
      return 0 if series.splits.empty?

      incoming = series.splits
      existing = instrument.split_events
                           .where(ex_date: incoming.map(&:ex_date))
                           .pluck(:ex_date).to_set
      rows = incoming.map { |s| { instrument_id: instrument.id, ex_date: s.ex_date, ratio: s.ratio } }
      SplitEvent.upsert_all(rows, unique_by: %i[instrument_id ex_date], record_timestamps: true)
      incoming.count { |s| existing.exclude?(s.ex_date) }
    end

    def write_dividends
      return 0 if series.dividends.empty?

      incoming = series.dividends
      existing = instrument.dividend_events
                           .where(ex_date: incoming.map(&:ex_date))
                           .pluck(:ex_date).to_set
      rows = incoming.map { |d| { instrument_id: instrument.id, ex_date: d.ex_date, cash_per_share: d.cash_per_share } }
      DividendEvent.upsert_all(rows, unique_by: %i[instrument_id ex_date], record_timestamps: true)
      incoming.count { |d| existing.exclude?(d.ex_date) }
    end

    def advance_bounds(bars)
      return [ instrument.earliest_price_on, instrument.latest_price_on ] if bars.empty?

      dates = bars.map(&:date)
      new_earliest = [ dates.min, instrument.earliest_price_on ].compact.min
      new_latest   = [ dates.max, instrument.latest_price_on ].compact.max

      if new_earliest != instrument.earliest_price_on || new_latest != instrument.latest_price_on
        instrument.update_columns(earliest_price_on: new_earliest, latest_price_on: new_latest)
      end
      [ new_earliest, new_latest ]
    end
  end
end
