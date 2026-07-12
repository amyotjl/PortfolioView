require "test_helper"

class Prices::DailySyncJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include PricePipelineTestHelper

  ET = ActiveSupport::TimeZone["America/New_York"]

  # A Tuesday and a Saturday in ET, used to prove the trading-day self-gate.
  TRADING_DAY = ET.local(2026, 7, 7, 22)      # Tue
  WEEKEND_DAY = ET.local(2026, 7, 11, 22)     # Sat

  setup do
    @user = users(:one)
    @portfolio = @user.portfolios.create!(name: "Main")

    @traded = create_instrument(symbol: "AAPL")
    @portfolio.transactions.create!(instrument: @traded, side: "buy", kind: "normal",
                                    shares: 1, price: 100, executed_on: Date.new(2024, 1, 2))

    @recurring = create_instrument(symbol: "VOO")
    @portfolio.recurring_transactions.create!(instrument: @recurring, side: "buy", amount_type: "dollars",
                                              dollar_amount: 100, frequency: "monthly",
                                              anchor_on: Date.new(2024, 1, 31), next_run_on: Date.new(2024, 1, 31))

    @benchmarked = create_instrument(symbol: "SPY")
    Benchmark.create!(instrument: @benchmarked, name: "S&P 500")

    # Referenced by nothing → must NOT be synced.
    @orphan = create_instrument(symbol: "ORPHAN")
  end

  test "fans out one FetchInstrumentJob per referenced instrument, excluding orphans" do
    travel_to TRADING_DAY do
      assert_enqueued_jobs 3, only: Prices::FetchInstrumentJob do
        Prices::DailySyncJob.perform_now
      end
    end

    fetched_ids = fetch_arguments.map(&:first)
    assert_equal [ @traded.id, @recurring.id, @benchmarked.id ].sort, fetched_ids.sort
    assert_not_includes fetched_ids, @orphan.id
  end

  test "a weekend run is a cheap idempotent no-op (no fan-out)" do
    travel_to WEEKEND_DAY do
      assert_no_enqueued_jobs only: Prices::FetchInstrumentJob do
        Prices::DailySyncJob.perform_now
      end
    end
  end

  test "paces the fan-out under the hourly window using the breaker limit" do
    12.times do |i|
      ref = create_instrument(symbol: "PACE#{i}")
      @portfolio.transactions.create!(instrument: ref, side: "buy", kind: "normal",
                                      shares: 1, price: 1, executed_on: Date.new(2024, 1, 2))
    end

    tiny_pace = PriceProvider::Budget.new("tiingo", limits: { daily: 1000, hourly: 5, monthly_symbols: 500 })

    travel_to TRADING_DAY do
      stub_new(PriceProvider::Budget, tiny_pace) do
        Prices::DailySyncJob.perform_now
      end

      frozen_now = Time.now.to_f
      staggered = enqueued_fetches.count { |j| j[:at] && j[:at] - frozen_now > 1_800 }
      assert_operator enqueued_fetches.size, :>, 5
      assert_operator staggered, :>, 0, "later fetches must be staggered past the hourly window"
    end
  end

  private

  def enqueued_fetches
    enqueued_jobs.select { |j| j["job_class"] == "Prices::FetchInstrumentJob" }
  end

  def fetch_arguments
    enqueued_fetches.map { |j| j["arguments"] }
  end
end
