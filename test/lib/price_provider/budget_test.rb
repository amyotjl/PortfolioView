require "test_helper"

# Unit tests for the per-provider budget circuit breakers. These exercise real
# Rails.cache counters (memory_store in the test env, cleared between tests) and
# travel_to to prove the day/month/hour rollover boundaries in America/New_York.
class PriceProvider::BudgetTest < ActiveSupport::TestCase
  ET = ActiveSupport::TimeZone["America/New_York"]

  def build(provider = "test_provider", **limits)
    defaults = { daily: 3, hourly: 2, monthly_symbols: 2 }
    PriceProvider::Budget.new(provider, limits: defaults.merge(limits))
  end

  test "built-in provider limits mirror the plan's free tiers" do
    tiingo = PriceProvider::Budget.new("tiingo")
    assert_equal 1_000, tiingo.daily_limit
    assert_equal 50, tiingo.hourly_limit
    assert_equal 500, tiingo.monthly_symbol_limit

    assert_equal 800, PriceProvider::Budget.new("twelve_data").daily_limit
    assert_equal 250, PriceProvider::Budget.new("fmp").daily_limit
    assert_nil PriceProvider::Budget.new("fmp").monthly_symbol_limit
  end

  test "an unknown provider without explicit limits is rejected" do
    assert_raises ArgumentError do
      PriceProvider::Budget.new("nope")
    end
  end

  test "the daily budget raises a typed BudgetExceeded once it is hit" do
    budget = build(daily: 3, hourly: 100)

    travel_to ET.local(2026, 7, 11, 10) do
      3.times { budget.charge! }
      assert_equal 0, budget.remaining_today

      error = assert_raises PriceProvider::BudgetExceeded do
        budget.charge!
      end
      # BudgetExceeded is a RateLimited carrying retry_after seconds.
      assert_kind_of PriceProvider::RateLimited, error
      assert error.retry_after.positive?
      assert_operator error.retry_after, :<=, 86_400
    end
  end

  test "a refused charge does not advance the counter (no half-charge)" do
    budget = build(daily: 2, hourly: 100)

    travel_to ET.local(2026, 7, 11, 10) do
      2.times { budget.charge! }
      3.times { assert_raises(PriceProvider::BudgetExceeded) { budget.charge! } }
      assert_equal 2, budget.requests_today
    end
  end

  test "the daily counter resets at the day boundary in America/New_York" do
    budget = build(daily: 2, hourly: 100)

    travel_to ET.local(2026, 7, 11, 23, 30) do
      2.times { budget.charge! }
      assert_raises(PriceProvider::BudgetExceeded) { budget.charge! }
    end

    travel_to ET.local(2026, 7, 12, 0, 30) do
      assert_equal 0, budget.requests_today
      assert_nothing_raised { budget.charge! }
    end
  end

  test "the hourly pacing window trips independently and resets each hour" do
    budget = build(daily: 100, hourly: 2)

    travel_to ET.local(2026, 7, 11, 14, 15) do
      2.times { budget.charge! }
      error = assert_raises PriceProvider::BudgetExceeded do
        budget.charge!
      end
      assert_match(/hourly/i, error.message)
      assert error.retry_after.positive?
      assert_operator error.retry_after, :<=, 3_600
    end

    travel_to ET.local(2026, 7, 11, 15, 5) do
      assert_equal 0, budget.requests_this_hour
      assert_nothing_raised { budget.charge! }
    end
  end

  test "unique-symbol counter increments once per distinct symbol, never twice" do
    budget = build(monthly_symbols: 10)

    travel_to ET.local(2026, 7, 11, 12) do
      budget.register_symbol!("AAPL")
      budget.register_symbol!("aapl") # same symbol, different case
      budget.register_symbol!("AAPL")
      assert_equal 1, budget.unique_symbols_this_month

      budget.register_symbol!("MSFT")
      assert_equal 2, budget.unique_symbols_this_month
    end
  end

  test "unique-symbol counter rolls over at the month boundary in America/New_York" do
    budget = build(monthly_symbols: 10)

    travel_to ET.local(2026, 1, 31, 20) do
      budget.register_symbol!("AAPL")
      assert_equal 1, budget.unique_symbols_this_month
    end

    travel_to ET.local(2026, 2, 1, 9) do
      assert_equal 0, budget.unique_symbols_this_month
      budget.register_symbol!("AAPL") # counts again in the new month
      assert_equal 1, budget.unique_symbols_this_month
    end
  end

  test "a NEW symbol beyond the monthly cap raises; a known symbol stays free" do
    budget = build(monthly_symbols: 2)

    travel_to ET.local(2026, 7, 11, 12) do
      budget.register_symbol!("AAPL")
      budget.register_symbol!("MSFT")
      assert_equal 2, budget.unique_symbols_this_month

      # A brand-new third symbol is refused and NOT counted (rollback).
      error = assert_raises PriceProvider::BudgetExceeded do
        budget.register_symbol!("GOOG")
      end
      assert_kind_of PriceProvider::RateLimited, error
      assert_equal 2, budget.unique_symbols_this_month

      # Re-registering the refused symbol still raises (never silently free).
      assert_raises(PriceProvider::BudgetExceeded) { budget.register_symbol!("GOOG") }

      # An already-counted symbol remains free even at the cap.
      assert_nothing_raised { budget.register_symbol!("AAPL") }
      assert_equal 2, budget.unique_symbols_this_month
    end
  end

  test "register_symbol! is unavailable on a provider with no monthly quota" do
    assert_raises ArgumentError do
      PriceProvider::Budget.new("fmp").register_symbol!("AAPL")
    end
  end

  test "charge! rejects a non-positive cost" do
    assert_raises(ArgumentError) { build.charge!(0) }
    assert_raises(ArgumentError) { build.charge!(-1) }
  end

  test "charge! with a cost > 1 debits the whole cost at once" do
    budget = build(daily: 5, hourly: 100)

    travel_to ET.local(2026, 7, 11, 10) do
      budget.charge!(3)
      assert_equal 2, budget.remaining_today
      assert_raises(PriceProvider::BudgetExceeded) { budget.charge!(3) } # would exceed 5
      assert_equal 2, budget.remaining_today
    end
  end
end
