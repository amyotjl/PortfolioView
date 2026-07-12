require "test_helper"

# Materializer core (docs/PLAN.md § Recurring materializer / § Verification):
# full catch-up in one run, each slot at its own historical execution-date
# close, idempotent under double runs, anchored advancement.
class Recurring::MaterializerTest < ActiveSupport::TestCase
  include DomainTestHelper

  TODAY = Date.new(2026, 4, 1)
  ANCHOR = Date.new(2026, 1, 31) # a Saturday: execution date must roll to Monday Feb-2

  setup do
    @portfolio = create_portfolio
    @voo = create_instrument(symbol: "VOO", instrument_type: "etf")
    create_trading_days(Date.new(2026, 1, 2), Date.new(2026, 3, 31))
    seed_prices(@voo, {
      Date.new(2026, 2, 2) => "250",  # fills the Jan-31 slot
      Date.new(2026, 3, 2) => "400",  # fills the Feb-28 slot
      Date.new(2026, 3, 31) => "500"  # fills the Mar-31 slot
    })
  end

  def create_rule(instrument: @voo, next_run_on: ANCHOR, anchor_on: ANCHOR, **attrs)
    rule = RecurringTransaction.create!({
      portfolio: @portfolio, instrument: instrument,
      side: "buy", amount_type: "dollars", dollar_amount: "500.00",
      frequency: "monthly", anchor_on: anchor_on,
      next_run_on: Date.new(2099, 1, 1) # placeholder; rewound below, clamp-proof
    }.merge(attrs))
    rule.update_columns(next_run_on: next_run_on)
    rule.reload
  end

  def materialize(rule, today: TODAY)
    Recurring::Materializer.call(rule: rule, today: today)
  end

  test "catches up every missed slot in ONE run, each at its own historical close" do
    rule = create_rule

    result = materialize(rule)

    assert_equal 3, result.filled
    assert_equal :caught_up, result.stopped

    trades = rule.transactions.order(:scheduled_for)
    assert_equal [ Date.new(2026, 1, 31), Date.new(2026, 2, 28), Date.new(2026, 3, 31) ],
                 trades.map(&:scheduled_for), "slots stay on the anchor sequence"
    assert_equal [ Date.new(2026, 2, 2), Date.new(2026, 3, 2), Date.new(2026, 3, 31) ],
                 trades.map(&:executed_on), "execution date = first trading day >= slot"
    assert_equal [ bd("250"), bd("400"), bd("500") ], trades.map(&:price),
                 "each slot fills at its own execution-date close, not today's"
    assert_equal [ bd("2"), bd("1.25"), bd("1") ], trades.map(&:shares)
    assert_equal Date.new(2026, 4, 30), rule.reload.next_run_on
    assert(trades.all? { |t| t.side == "buy" && t.kind == "normal" && t.recurring_transaction_id == rule.id })
  end

  test "shares = dollar_amount / close rounded to 8 dp" do
    seed_prices(@voo, { Date.new(2026, 3, 31) => "300" })
    rule = create_rule(next_run_on: Date.new(2026, 3, 31), anchor_on: Date.new(2026, 3, 31))

    materialize(rule)

    assert_equal bd("1.66666667"), rule.transactions.sole.shares, "500/300 rounded half-up at 8 dp"
  end

  test "share-amount rules use share_amount directly" do
    rule = create_rule(next_run_on: Date.new(2026, 3, 31), anchor_on: Date.new(2026, 3, 31),
                       amount_type: "shares", dollar_amount: nil, share_amount: "0.50000001")

    materialize(rule)

    trade = rule.transactions.sole
    assert_equal bd("0.50000001"), trade.shares
    assert_equal bd("500"), trade.price, "priced at the execution-date close"
  end

  test "a double run inserts nothing extra" do
    rule = create_rule

    materialize(rule)
    second = materialize(rule)

    assert_equal 0, second.filled
    assert_equal 3, rule.transactions.count
  end

  test "a rewound next_run_on (crash between insert and advance) self-heals without duplicates" do
    rule = create_rule
    materialize(rule)

    rule.update_columns(next_run_on: ANCHOR) # simulate the crash / stale cursor
    result = materialize(rule.reload)

    assert_equal 0, result.filled, "already-filled slots are advanced past, not re-inserted"
    assert_equal 3, rule.transactions.count
    assert_equal Date.new(2026, 4, 30), rule.reload.next_run_on
  end

  test "each materialized insert bumps the portfolio's series_version" do
    rule = create_rule
    assert_equal 1, @portfolio.reload.series_version

    materialize(rule)

    assert_equal 4, @portfolio.reload.series_version, "three inserts, three bumps"
  end

  test "a missing instrument close on the execution date halts WITHOUT advancing (slot retried next run)" do
    bare = create_instrument(symbol: "NOPX")
    rule = create_rule(instrument: bare)

    result = materialize(rule)

    assert_equal 0, result.filled
    assert_equal :missing_price, result.stopped
    assert_equal ANCHOR, rule.reload.next_run_on, "the slot must not be silently skipped"
    assert_equal 0, rule.transactions.count
  end

  test "a slot whose execution date has not traded yet halts without advancing" do
    # Saturday Jan-31 slot, run ON Saturday: Monday's close does not exist yet.
    rule = create_rule

    result = materialize(rule, today: ANCHOR)

    assert_equal 0, result.filled
    assert_equal :awaiting_data, result.stopped
    assert_equal ANCHOR, rule.reload.next_run_on
  end

  test "a slot beyond the price cache halts without advancing" do
    rule = create_rule(next_run_on: Date.new(2026, 4, 1), anchor_on: Date.new(2026, 4, 1))

    result = materialize(rule) # calendar ends Mar-31

    assert_equal :awaiting_data, result.stopped
    assert_equal Date.new(2026, 4, 1), rule.reload.next_run_on
  end

  test "an inactive rule is a no-op" do
    rule = create_rule
    rule.update_columns(active: false)

    result = materialize(rule.reload)

    assert_equal 0, result.filled
    assert_equal :inactive, result.stopped
    assert_equal 0, rule.transactions.count
  end

  test "materialized shares and prices are BigDecimal" do
    rule = create_rule

    materialize(rule)

    rule.transactions.each do |trade|
      assert_instance_of BigDecimal, trade.shares
      assert_instance_of BigDecimal, trade.price
    end
  end
end
