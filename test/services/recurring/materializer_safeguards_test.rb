require "test_helper"

# Lifecycle safeguards (backlog #023, docs/PLAN.md § Recurring materializer):
# skip counting with pause-after-N (no silent forever-skip), end_on
# deactivation, counter reset on success.
class Recurring::MaterializerSafeguardsTest < ActiveSupport::TestCase
  include DomainTestHelper

  TODAY = Date.new(2026, 4, 1)
  ANCHOR = Date.new(2026, 1, 31)

  setup do
    @portfolio = create_portfolio
    @voo = create_instrument(symbol: "VOO", instrument_type: "etf")
    @dark = create_instrument(symbol: "NOPX") # never gets a price row
    create_trading_days(Date.new(2026, 1, 2), Date.new(2026, 3, 31))
    seed_prices(@voo, {
      Date.new(2026, 2, 2) => "250",
      Date.new(2026, 3, 2) => "400",
      Date.new(2026, 3, 31) => "500"
    })
  end

  def create_rule(instrument: @voo, next_run_on: ANCHOR, anchor_on: ANCHOR, **attrs)
    rule = RecurringTransaction.create!({
      portfolio: @portfolio, instrument: instrument,
      side: "buy", amount_type: "dollars", dollar_amount: "500.00",
      frequency: "monthly", anchor_on: anchor_on,
      next_run_on: Date.new(2099, 1, 1)
    }.merge(attrs))
    rule.update_columns(next_run_on: next_run_on)
    rule.reload
  end

  def materialize(rule, today: TODAY, **opts)
    Recurring::Materializer.call(rule: rule, today: today, **opts)
  end

  test "consecutive_skips increments on each missing-price run and the rule stays active below the limit" do
    rule = create_rule(instrument: @dark)

    first = materialize(rule)
    assert_equal :missing_price, first.stopped
    assert_equal 1, rule.reload.consecutive_skips
    assert rule.active
    assert_nil rule.paused_reason

    second = materialize(rule)
    assert_equal :missing_price, second.stopped
    assert_equal 2, rule.reload.consecutive_skips
    assert rule.active
  end

  test "after N consecutive skips the rule pauses itself with a reason (no silent forever-skip)" do
    rule = create_rule(instrument: @dark)

    materialize(rule, max_consecutive_skips: 2)
    result = materialize(rule.reload, max_consecutive_skips: 2)

    assert_equal :paused, result.stopped
    rule.reload
    assert_not rule.active
    assert_equal 2, rule.consecutive_skips
    assert_match(/2 consecutive missing-price skips/, rule.paused_reason)
    assert_match(/NOPX/, rule.paused_reason)
    assert_match(/2026-02-02/, rule.paused_reason, "the reason names the priceless execution date")
    assert_equal ANCHOR, rule.next_run_on, "the unfilled slot is preserved for a manual retry"
  end

  test "a paused rule is inert until reactivated" do
    rule = create_rule(instrument: @dark)
    materialize(rule, max_consecutive_skips: 1)

    result = materialize(rule.reload)

    assert_equal :inactive, result.stopped
    assert_equal 1, rule.reload.consecutive_skips, "no further counting while paused"
  end

  test "a successful materialization resets consecutive_skips to zero" do
    rule = create_rule
    rule.update_columns(consecutive_skips: 3)

    materialize(rule.reload)

    assert_equal 0, rule.reload.consecutive_skips
    assert rule.active
  end

  test "a due slot past end_on deactivates the rule after earlier slots still materialize" do
    rule = create_rule(end_on: Date.new(2026, 2, 15))

    result = materialize(rule)

    assert_equal 1, result.filled, "the Jan-31 slot (<= end_on) still fills"
    assert_equal :deactivated, result.stopped
    rule.reload
    assert_not rule.active
    assert_nil rule.paused_reason, "deactivation past end_on is not a pause"
    assert_equal Date.new(2026, 2, 28), rule.next_run_on
    assert_equal [ Date.new(2026, 1, 31) ], rule.transactions.pluck(:scheduled_for)
  end

  test "a rule already past end_on deactivates without materializing anything" do
    rule = create_rule(end_on: Date.new(2026, 1, 15))

    result = materialize(rule)

    assert_equal 0, result.filled
    assert_equal :deactivated, result.stopped
    assert_not rule.reload.active
    assert_equal 0, rule.transactions.count
  end

  test "an awaiting-data halt is NOT counted as a skip" do
    rule = create_rule(next_run_on: Date.new(2026, 4, 1), anchor_on: Date.new(2026, 4, 1))

    result = materialize(rule) # calendar ends Mar-31

    assert_equal :awaiting_data, result.stopped
    assert_equal 0, rule.reload.consecutive_skips
    assert rule.active
  end
end
