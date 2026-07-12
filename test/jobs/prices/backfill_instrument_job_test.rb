require "test_helper"

class Prices::BackfillInstrumentJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include PricePipelineTestHelper

  ET = ActiveSupport::TimeZone["America/New_York"]

  setup do
    @instrument = create_instrument(symbol: "AAPL")
    @series = build_series(
      symbol: "AAPL",
      bars: [
        { date: Date.new(2020, 8, 28), open: 126, high: 126.4, low: 124.5, close: 124.8, volume: 1 },
        { date: Date.new(2020, 8, 31), open: 127, high: 131, low: 126, close: 129, volume: 1 }
      ],
      splits: [ { ex_date: Date.new(2020, 8, 31), ratio: 4 } ],
      dividends: [ { ex_date: Date.new(2020, 8, 28), cash_per_share: 0.205 } ]
    )
  end

  def run_with_provider(provider)
    travel_to ET.local(2026, 7, 11, 20) do
      stub_new(PriceProvider::Tiingo, provider) do
        Prices::BackfillInstrumentJob.perform_now(@instrument.id)
      end
    end
  end

  test "backfills full history + splits + dividends and sets the backfill markers" do
    provider = StubProvider.new(series: @series)

    run_with_provider(provider)

    assert_equal [ :full_history, "AAPL", nil ], provider.calls.first
    assert_equal 2, @instrument.daily_prices.count
    assert_equal 1, @instrument.split_events.count
    assert_equal 1, @instrument.dividend_events.count

    @instrument.reload
    assert_not_nil @instrument.prices_backfilled_at
    assert_equal Date.new(2020, 8, 28), @instrument.earliest_price_on
    assert_equal Date.new(2020, 8, 31), @instrument.latest_price_on
  end

  test "bumps series_version only for portfolios holding the instrument" do
    user = users(:one)
    holder = user.portfolios.create!(name: "Holder")
    holder.transactions.create!(instrument: @instrument, side: "buy", kind: "normal",
                                shares: 1, price: 100, executed_on: Date.new(2024, 1, 2))
    bystander = user.portfolios.create!(name: "Bystander")

    assert_equal 1, holder.series_version
    assert_equal 1, bystander.series_version

    run_with_provider(StubProvider.new(series: @series))

    assert_equal 2, holder.reload.series_version
    assert_equal 1, bystander.reload.series_version
  end

  test "bumps series_version for a portfolio referencing the instrument via a recurring rule" do
    user = users(:one)
    portfolio = user.portfolios.create!(name: "Recurring holder")
    portfolio.recurring_transactions.create!(instrument: @instrument, side: "buy", amount_type: "dollars",
                                             dollar_amount: 100, frequency: "monthly",
                                             anchor_on: Date.new(2024, 1, 31), next_run_on: Date.new(2024, 1, 31))

    run_with_provider(StubProvider.new(series: @series))

    assert_equal 2, portfolio.reload.series_version
  end

  test "re-running the backfill is idempotent (row counts unchanged)" do
    run_with_provider(StubProvider.new(series: @series))
    run_with_provider(StubProvider.new(series: @series))

    assert_equal 2, @instrument.daily_prices.count
    assert_equal 1, @instrument.split_events.count
    assert_equal 1, @instrument.dividend_events.count
  end

  test "consumes the Tiingo unique-symbol and request budgets" do
    travel_to ET.local(2026, 7, 11, 20) do
      stub_new(PriceProvider::Tiingo, StubProvider.new(series: @series)) do
        Prices::BackfillInstrumentJob.perform_now(@instrument.id)
      end

      budget = PriceProvider::Budget.new("tiingo")
      assert_equal 1, budget.unique_symbols_this_month
      assert_equal 1, budget.requests_today
    end
  end

  test "reschedules and stays un-backfilled when the request budget is exhausted" do
    travel_to ET.local(2026, 7, 11, 20) do
      # Fill the real hourly pacing window (50/hr) so the job's own charge! trips
      # BudgetExceeded — exercising the real breaker, not a stub.
      PriceProvider::Budget.new("tiingo").charge!(50)
      clear_enqueued_jobs # drop the create-time backfill so we assert the reschedule

      stub_new(PriceProvider::Tiingo, StubProvider.new(series: @series)) do
        Prices::BackfillInstrumentJob.perform_now(@instrument.id)
      end
    end

    assert_enqueued_with(job: Prices::BackfillInstrumentJob, args: [ @instrument.id ])
    assert_nil @instrument.reload.prices_backfilled_at
    assert_equal 0, @instrument.daily_prices.count
  end

  test "discards and flags an unknown symbol without writing or raising" do
    provider = StubProvider.new(error: PriceProvider::UnknownSymbol.new("tiingo: not found"))

    assert_nothing_raised do
      run_with_provider(provider)
    end

    assert_equal 0, @instrument.daily_prices.count
    assert_nil @instrument.reload.prices_backfilled_at
  end
end

# The after_create_commit trigger only fires on a real COMMIT, which the default
# transactional-test wrapper rolls back — so this focused case disables it and
# cleans up the row it creates.
class InstrumentBackfillTriggerTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include PricePipelineTestHelper

  self.use_transactional_tests = false

  teardown { Instrument.where(symbol: "TRIGGERTEST").delete_all }

  test "creating an instrument enqueues its backfill on commit" do
    assert_enqueued_with(job: Prices::BackfillInstrumentJob) do
      create_instrument(symbol: "TRIGGERTEST")
    end
  end
end
