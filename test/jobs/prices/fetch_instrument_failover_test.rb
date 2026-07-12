require "test_helper"

# backlog #014: TwelveData failover for FORWARD DELTAS ONLY.
class Prices::FetchInstrumentFailoverTest < ActiveSupport::TestCase
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
    @instrument.daily_prices.create!(date: Date.new(2024, 1, 5), open: 100, high: 101,
                                     low: 99, close: 100, volume: 1, source: "tiingo")
  end

  def delta(overlap_close: 100, splits: [])
    build_series(symbol: "AAPL",
      bars: [
        { date: Date.new(2024, 1, 5), open: overlap_close, high: overlap_close, low: overlap_close, close: overlap_close, volume: 1 },
        { date: Date.new(2024, 1, 8), open: 106, high: 108, low: 105, close: 107, volume: 1 }
      ],
      splits: splits)
  end

  test "a Tiingo delta failure lands the delta via TwelveData, recording source per row" do
    tiingo = StubProvider.new(error: PriceProvider::ServerError.new("tiingo down"))
    td = StubProvider.new(series: delta(overlap_close: 100))

    travel_to ET.local(2026, 7, 11, 20) do
      stub_new(PriceProvider::Tiingo, tiingo) do
        stub_new(PriceProvider::TwelveData, td) do
          Prices::FetchInstrumentJob.perform_now(@instrument.id)
        end
      end
    end

    # The delta window (since = latest_price_on, inclusive) was fetched from TwelveData.
    assert_equal [ :fetch_delta, "AAPL", Date.new(2024, 1, 5), nil ], td.calls.first
    new_row = @instrument.daily_prices.find_by(date: Date.new(2024, 1, 8))
    assert_not_nil new_row
    assert_equal "twelve_data", new_row.source
    assert_equal Date.new(2024, 1, 8), @instrument.reload.latest_price_on
  end

  test "an exhausted Tiingo budget fails over to TwelveData for the delta window" do
    td = StubProvider.new(series: delta(overlap_close: 100))

    travel_to ET.local(2026, 7, 11, 20) do
      PriceProvider::Budget.new("tiingo").charge!(50) # trip the hourly window
      stub_new(PriceProvider::TwelveData, td) do
        Prices::FetchInstrumentJob.perform_now(@instrument.id)
      end
    end

    assert td.called?(:fetch_delta), "budget exhaustion must fail over, not just reschedule"
    assert_equal "twelve_data", @instrument.daily_prices.find_by(date: Date.new(2024, 1, 8)).source
  end

  test "the failover path never writes split or dividend events" do
    tiingo = StubProvider.new(error: PriceProvider::ServerError.new("tiingo down"))
    # A misbehaving fallback that returns a split must still not have it persisted.
    td = StubProvider.new(series: delta(overlap_close: 100, splits: [ { ex_date: Date.new(2024, 1, 8), ratio: 2 } ]))

    travel_to ET.local(2026, 7, 11, 20) do
      stub_new(PriceProvider::Tiingo, tiingo) do
        stub_new(PriceProvider::TwelveData, td) do
          Prices::FetchInstrumentJob.perform_now(@instrument.id)
        end
      end
    end

    assert_equal 0, @instrument.split_events.count
    assert_equal 0, @instrument.dividend_events.count
  end

  test "an unknown symbol never fails over — it discards without touching TwelveData" do
    tiingo = StubProvider.new(error: PriceProvider::UnknownSymbol.new("tiingo: not found"))
    td = StubProvider.new(series: delta)

    travel_to ET.local(2026, 7, 11, 20) do
      stub_new(PriceProvider::Tiingo, tiingo) do
        stub_new(PriceProvider::TwelveData, td) do
          assert_nothing_raised { Prices::FetchInstrumentJob.perform_now(@instrument.id) }
        end
      end
    end

    assert_equal 0, td.call_count, "an unknown symbol is unknown everywhere; do not fail over"
    assert_equal 1, @instrument.daily_prices.count # nothing new written
  end

  test "a backfill failure never fails over — zero TwelveData calls, left un-backfilled" do
    fresh = create_instrument(symbol: "NFLX")
    tiingo = StubProvider.new(error: PriceProvider::ServerError.new("tiingo down"))
    td = StubProvider.new(series: delta)

    travel_to ET.local(2026, 7, 11, 20) do
      stub_new(PriceProvider::Tiingo, tiingo) do
        stub_new(PriceProvider::TwelveData, td) do
          Prices::BackfillInstrumentJob.perform_now(fresh.id)
        end
      end
    end

    assert_equal 0, td.call_count, "a backfill must never reach for the fallback"
    assert_nil fresh.reload.prices_backfilled_at
    assert_equal 0, fresh.daily_prices.count
  end
end
