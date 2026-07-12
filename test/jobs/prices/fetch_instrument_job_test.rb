require "test_helper"

class Prices::FetchInstrumentJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include PricePipelineTestHelper

  ET = ActiveSupport::TimeZone["America/New_York"]

  setup do
    @instrument = create_instrument(symbol: "AAPL")
    @instrument.update_columns(
      prices_backfilled_at: Time.utc(2024, 1, 1),
      earliest_price_on: Date.new(2020, 1, 1),
      latest_price_on: Date.new(2024, 1, 5)
    )
    # The stored overlap-day close the drift check probes against.
    @instrument.daily_prices.create!(date: Date.new(2024, 1, 5), open: 100, high: 101,
                                     low: 99, close: 100, volume: 1, source: "tiingo")
  end

  def run_with(provider)
    travel_to ET.local(2026, 7, 11, 20) do
      stub_new(PriceProvider::Tiingo, provider) do
        Prices::FetchInstrumentJob.perform_now(@instrument.id)
      end
    end
  end

  test "declares limits_concurrency so per-instrument fetches serialize" do
    assert_equal 1, Prices::FetchInstrumentJob.concurrency_limit
    assert Prices::FetchInstrumentJob.concurrency_key?, "expected a concurrency key proc"
  end

  test "fetches from latest_price_on INCLUSIVE (the overlap row is the drift probe)" do
    provider = StubProvider.new(series: overlap_and_new(overlap_close: 100))

    run_with(provider)

    assert_equal [ :fetch_daily, "AAPL", Date.new(2024, 1, 5), nil ], provider.calls.first
  end

  test "upserts new rows and advances latest_price_on when the overlap is within tolerance" do
    provider = StubProvider.new(series: overlap_and_new(overlap_close: 105)) # +5%, within 20%

    run_with(provider)

    assert_equal [ Date.new(2024, 1, 5), Date.new(2024, 1, 8) ], @instrument.daily_prices.order(:date).pluck(:date)
    assert_equal BigDecimal("105"), @instrument.daily_prices.find_by(date: Date.new(2024, 1, 5)).close
    assert_equal Date.new(2024, 1, 8), @instrument.reload.latest_price_on
  end

  test "flags basis drift and aborts writes on a >20% overlap mismatch" do
    provider = StubProvider.new(series: overlap_and_new(overlap_close: 130)) # +30%

    run_with(provider)

    # No new row written, stored close untouched, bound not advanced.
    assert_equal [ Date.new(2024, 1, 5) ], @instrument.daily_prices.pluck(:date)
    assert_equal BigDecimal("100"), @instrument.daily_prices.sole.close
    assert_equal Date.new(2024, 1, 5), @instrument.reload.latest_price_on
  end

  test "double-running is idempotent (row counts unchanged)" do
    provider = StubProvider.new(series: overlap_and_new(overlap_close: 100))

    run_with(provider)
    run_with(StubProvider.new(series: overlap_and_new(overlap_close: 100)))

    assert_equal 2, @instrument.daily_prices.count
  end

  test "bumps series_version only when a late-discovered split is written" do
    user = users(:one)
    portfolio = user.portfolios.create!(name: "Holder")
    portfolio.transactions.create!(instrument: @instrument, side: "buy", kind: "normal",
                                   shares: 1, price: 100, executed_on: Date.new(2024, 1, 2))

    with_split = overlap_and_new(overlap_close: 100)
    with_split = build_series(symbol: "AAPL",
      bars: with_split.bars.map { |b| { date: b.date, open: b.open, high: b.high, low: b.low, close: b.close, volume: b.volume } },
      splits: [ { ex_date: Date.new(2024, 1, 8), ratio: 2 } ])

    run_with(StubProvider.new(series: with_split))
    assert_equal 2, portfolio.reload.series_version, "a new split must bump series_version"

    # A subsequent plain fetch with no new split does not bump again.
    run_with(StubProvider.new(series: overlap_and_new(overlap_close: 100)))
    assert_equal 2, portfolio.reload.series_version
  end

  test "hands off to the backfill job when the instrument is not yet backfilled" do
    @instrument.update_columns(prices_backfilled_at: nil, latest_price_on: nil)
    provider = StubProvider.new(series: overlap_and_new(overlap_close: 100))

    run_with(provider)

    assert_equal 0, provider.call_count, "must not fetch a delta without an anchor"
    assert_enqueued_with(job: Prices::BackfillInstrumentJob, args: [ @instrument.id ])
  end

  test "reschedules on a rate-limited/budget-exhausted fetch" do
    travel_to ET.local(2026, 7, 11, 20) do
      PriceProvider::Budget.new("tiingo").charge!(50) # fill the hourly window
      stub_new(PriceProvider::Tiingo, StubProvider.new(series: overlap_and_new(overlap_close: 100))) do
        Prices::FetchInstrumentJob.perform_now(@instrument.id)
      end
    end

    assert_enqueued_with(job: Prices::FetchInstrumentJob, args: [ @instrument.id ])
    assert_equal 1, @instrument.daily_prices.count # nothing new written
  end

  private

  # Series covering the overlap day (latest_price_on) plus one new trading day.
  def overlap_and_new(overlap_close:)
    build_series(symbol: "AAPL", bars: [
      { date: Date.new(2024, 1, 5), open: overlap_close, high: overlap_close, low: overlap_close, close: overlap_close, volume: 1 },
      { date: Date.new(2024, 1, 8), open: 106, high: 108, low: 105, close: 107, volume: 1 }
    ])
  end
end
