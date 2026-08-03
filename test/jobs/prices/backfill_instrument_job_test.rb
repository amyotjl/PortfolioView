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

    # The transaction create above bumps series_version itself (backlog #019);
    # this test isolates the BACKFILL JOB's completion bump on top of that.
    holder_base = holder.reload.series_version
    assert_equal 1, bystander.series_version

    run_with_provider(StubProvider.new(series: @series))

    assert_equal holder_base + 1, holder.reload.series_version
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
  # --- issue #66: the Yahoo route is KEYLESS and must not be budgeted ---------
  #
  # #66's gate found this uncovered: deleting the `route.budgeted?` guard left
  # the whole 815-test suite green, so the branch's own stated safety property
  # had no test at all. Charging a Tiingo budget for a Yahoo fetch would burn a
  # scarce monthly unique-symbol slot on a provider that has no account, and
  # would reschedule Canadian backfills against a quota that does not apply.

  test "a venue-suffixed symbol backfills via Yahoo and charges NO budget" do
    canadian = create_instrument(symbol: "ZEQT.TO", currency: "CAD")
    series = build_series(symbol: "ZEQT.TO",
                          bars: [ { date: Date.new(2026, 7, 1), open: 20, high: 21, low: 19, close: 20.5, volume: 1 } ])
    provider = StubProvider.new(series: series)

    travel_to ET.local(2026, 7, 11, 20) do
      budget = PriceProvider::Budget.new("tiingo")
      before = budget.requests_today
      stub_new(PriceProvider::Yahoo, provider) do
        Prices::BackfillInstrumentJob.perform_now(canadian.id)
      end

      assert_equal before, budget.requests_today,
        "Yahoo is keyless — charging Tiingo's quota for it spends a budget that does not apply"
      assert_equal 0, budget.unique_symbols_this_month,
        "and must not consume a scarce monthly unique-symbol slot either"
    end

    assert_equal 1, canadian.daily_prices.count
    assert_equal "yahoo", canadian.daily_prices.first.source
  end

  test "an exhausted Tiingo budget does NOT block a Canadian backfill" do
    canadian = create_instrument(symbol: "VDY.TO", currency: "CAD")
    series = build_series(symbol: "VDY.TO",
                          bars: [ { date: Date.new(2026, 7, 1), open: 70, high: 80, low: 70, close: 78, volume: 1 } ])

    travel_to ET.local(2026, 7, 11, 20) do
      PriceProvider::Budget.new("tiingo").charge!(50) # fill Tiingo's hourly window
      stub_new(PriceProvider::Yahoo, StubProvider.new(series: series)) do
        Prices::BackfillInstrumentJob.perform_now(canadian.id)
      end
    end

    assert_equal 1, canadian.daily_prices.count,
      "a Canadian symbol has no dependence on Tiingo's quota and must still backfill"
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
