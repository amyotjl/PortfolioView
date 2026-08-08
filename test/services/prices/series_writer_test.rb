require "test_helper"

class Prices::SeriesWriterTest < ActiveSupport::TestCase
  include PricePipelineTestHelper

  setup { @instrument = create_instrument(symbol: "AAPL") }

  test "writes raw unadjusted prices with the given source and advances bounds" do
    series = build_series(bars: [
      { date: Date.new(2024, 1, 2), open: 10, high: 11, low: 9, close: 10.5, volume: 100 },
      { date: Date.new(2024, 1, 3), open: 10.5, high: 12, low: 10, close: 11.75, volume: 200 }
    ])

    result = Prices::SeriesWriter.call(instrument: @instrument, series: series, source: "tiingo")

    assert_equal 2, result.prices_written
    assert_equal 0, result.prices_skipped
    rows = @instrument.daily_prices.order(:date)
    assert_equal 2, rows.size
    assert_equal BigDecimal("10.5"), rows.first.close
    assert_equal "tiingo", rows.first.source
    assert_equal Date.new(2024, 1, 2), @instrument.reload.earliest_price_on
    assert_equal Date.new(2024, 1, 3), @instrument.latest_price_on
  end

  test "skips a malformed bar before the batch so one bad row cannot fail the batch" do
    series = build_series(bars: [
      { date: Date.new(2024, 1, 2), open: 10, high: 8, low: 9, close: 8.5, volume: 1 },  # high < low
      { date: Date.new(2024, 1, 3), open: 0, high: 11, low: 0, close: 10, volume: 1 },    # low = 0
      { date: Date.new(2024, 1, 4), open: 10, high: 11, low: 9, close: 10.5, volume: 1 }  # good
    ])

    result = Prices::SeriesWriter.call(instrument: @instrument, series: series, source: "tiingo")

    assert_equal 1, result.prices_written
    assert_equal 2, result.prices_skipped
    assert_equal [ Date.new(2024, 1, 4) ], @instrument.daily_prices.pluck(:date)
  end

  test "writes split and dividend events and reports the count of new splits" do
    series = build_series(
      bars: [ { date: Date.new(2020, 8, 31), open: 127, high: 131, low: 126, close: 129, volume: 1 } ],
      splits: [ { ex_date: Date.new(2020, 8, 31), ratio: 4 } ],
      dividends: [ { ex_date: Date.new(2020, 8, 31), cash_per_share: 0.205 } ]
    )

    result = Prices::SeriesWriter.call(instrument: @instrument, series: series, source: "tiingo")

    assert_equal 1, result.splits_written
    assert_equal 1, result.dividends_written
    assert_equal BigDecimal("4"), @instrument.split_events.sole.ratio
    assert_equal BigDecimal("0.205"), @instrument.dividend_events.sole.cash_per_share
  end

  test "write_events: false never writes split or dividend events (the failover guard)" do
    series = build_series(
      bars: [ { date: Date.new(2024, 1, 2), open: 10, high: 11, low: 9, close: 10.5, volume: 1 } ],
      splits: [ { ex_date: Date.new(2024, 1, 2), ratio: 2 } ],
      dividends: [ { ex_date: Date.new(2024, 1, 2), cash_per_share: 0.5 } ]
    )

    result = Prices::SeriesWriter.call(instrument: @instrument, series: series, source: "twelve_data", write_events: false)

    assert_equal 1, result.prices_written
    assert_equal 0, result.splits_written
    assert_equal 0, @instrument.split_events.count
    assert_equal 0, @instrument.dividend_events.count
  end

  test "re-running is idempotent: row counts unchanged and no new splits reported" do
    series = build_series(
      bars: [ { date: Date.new(2024, 1, 2), open: 10, high: 11, low: 9, close: 10.5, volume: 1 } ],
      splits: [ { ex_date: Date.new(2024, 1, 2), ratio: 2 } ]
    )

    Prices::SeriesWriter.call(instrument: @instrument, series: series, source: "tiingo")
    second = Prices::SeriesWriter.call(instrument: @instrument, series: series, source: "tiingo")

    assert_equal 1, @instrument.daily_prices.count
    assert_equal 1, @instrument.split_events.count
    assert_equal 0, second.splits_written, "an already-stored split is not counted as new on re-run"
  end

  test "advances latest_price_on without regressing an existing earlier bound" do
    @instrument.update_columns(earliest_price_on: Date.new(2020, 1, 1), latest_price_on: Date.new(2024, 1, 1))
    series = build_series(bars: [
      { date: Date.new(2024, 1, 2), open: 10, high: 11, low: 9, close: 10.5, volume: 1 }
    ])

    Prices::SeriesWriter.call(instrument: @instrument, series: series, source: "tiingo")

    @instrument.reload
    assert_equal Date.new(2020, 1, 1), @instrument.earliest_price_on
    assert_equal Date.new(2024, 1, 2), @instrument.latest_price_on
  end
  # --- #66 round 4: warnings must actually reach a log ------------------------

  test "every provider warning is logged, because nothing else reads them" do
    # DailySeries#warnings had no reader anywhere in the app: both jobs pass the
    # series straight to this class, which ignored the field. Every adapter
    # warning — including every suppressed corporate action — was silently
    # dropped, while the Yahoo adapter's own docs claimed the opposite.
    series = build_series(
      bars: [ { date: Date.new(2026, 1, 5), open: 10, high: 11, low: 9, close: 10.5, volume: 1 } ],
      warnings: [ "treated 9:10 on 2026-01-05 as price-only", "skipped bad EOD row" ]
    )

    logged = capture_log do
      Prices::SeriesWriter.call(instrument: @instrument, series: series, source: "yahoo")
    end

    assert_match(/treated 9:10 on 2026-01-05 as price-only/, logged)
    assert_match(/skipped bad EOD row/, logged)
    assert_match(/yahoo/, logged, "name the provider, so the line is actionable")
    assert_match(/#{@instrument.symbol}/, logged, "and the instrument")
  end

  test "a series with no warnings logs nothing" do
    series = build_series(
      bars: [ { date: Date.new(2026, 1, 5), open: 10, high: 11, low: 9, close: 10.5, volume: 1 } ],
      warnings: []
    )

    logged = capture_log do
      Prices::SeriesWriter.call(instrument: @instrument, series: series, source: "tiingo")
    end

    assert_no_match(/Prices::SeriesWriter/, logged)
  end

  def capture_log
    buffer = StringIO.new
    original = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(buffer)
    yield
    buffer.string
  ensure
    Rails.logger = original
  end
end
