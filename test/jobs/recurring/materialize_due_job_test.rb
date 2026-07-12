require "test_helper"

class Recurring::MaterializeDueJobTest < ActiveSupport::TestCase
  include DomainTestHelper

  setup do
    @portfolio = create_portfolio
    @voo = create_instrument(symbol: "VOO", instrument_type: "etf")
    create_trading_days(Date.new(2026, 3, 30), Date.new(2026, 3, 31))
    seed_prices(@voo, { Date.new(2026, 3, 31) => "500" })
  end

  def create_rule(next_run_on:, active: true)
    rule = RecurringTransaction.create!(
      portfolio: @portfolio, instrument: @voo,
      side: "buy", amount_type: "dollars", dollar_amount: "500.00",
      frequency: "monthly", anchor_on: Date.new(2026, 3, 31),
      next_run_on: Date.new(2099, 1, 1)
    )
    rule.update_columns(next_run_on: next_run_on, active: active)
    rule.reload
  end

  test "materializes due active rules and leaves future or inactive rules untouched" do
    due      = create_rule(next_run_on: Date.new(2026, 3, 31))
    future   = create_rule(next_run_on: Date.new(2026, 12, 31))
    inactive = create_rule(next_run_on: Date.new(2026, 3, 31), active: false)

    travel_to Time.utc(2026, 4, 1, 16, 0) do # noon April 1st in New York
      Recurring::MaterializeDueJob.perform_now
    end

    assert_equal 1, due.transactions.count
    assert_equal Date.new(2026, 3, 31), due.transactions.sole.scheduled_for
    assert_equal 0, future.transactions.count
    assert_equal 0, inactive.transactions.count
  end

  test "one failing rule does not starve the others" do
    exploding = create_rule(next_run_on: Date.new(2026, 3, 31))
    healthy   = create_rule(next_run_on: Date.new(2026, 3, 31))
    # The DB CHECK allows sell rules (v1.1); materializing one sells shares the
    # portfolio does not own, so Positions::Validator raises on the insert.
    exploding.update_columns(side: "sell")

    travel_to Time.utc(2026, 4, 1, 16, 0) do
      assert_nothing_raised { Recurring::MaterializeDueJob.perform_now }
    end

    assert_equal 1, healthy.transactions.count
  end
end
