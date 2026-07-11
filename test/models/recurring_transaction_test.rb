require "test_helper"

class RecurringTransactionTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email_address: "recurring@example.com", password: "password")
    @portfolio = Portfolio.create!(user: @user, name: "Main")
    @instrument = Instrument.create!(symbol: "VOO", instrument_type: "etf")
  end

  def rule_attrs(overrides = {})
    {
      portfolio: @portfolio, instrument: @instrument,
      side: "buy", amount_type: "dollars", dollar_amount: "500.00",
      frequency: "monthly", anchor_on: Date.new(2026, 1, 31), next_run_on: Date.new(2026, 8, 31)
    }.merge(overrides)
  end

  test "model validation enforces buy-only in v1" do
    rule = RecurringTransaction.new(rule_attrs(side: "sell"))

    assert_not rule.valid?
    assert rule.errors[:side].any?
  end

  test "CHECK rejects an unknown frequency at the DB level" do
    error = assert_raises ActiveRecord::StatementInvalid do
      RecurringTransaction.new(rule_attrs(frequency: "daily")).save!(validate: false)
    end
    assert_match(/recurring_transactions_frequency_check/, error.message)
  end

  test "CHECK rejects a dollars rule carrying a share_amount at the DB level" do
    error = assert_raises ActiveRecord::StatementInvalid do
      RecurringTransaction.new(rule_attrs(share_amount: "1.5")).save!(validate: false)
    end
    assert_match(/recurring_transactions_amount_presence_check/, error.message)
  end

  test "CHECK rejects a shares rule with no share_amount at the DB level" do
    error = assert_raises ActiveRecord::StatementInvalid do
      RecurringTransaction.new(rule_attrs(amount_type: "shares", dollar_amount: nil,
                                          share_amount: nil)).save!(validate: false)
    end
    assert_match(/recurring_transactions_amount_presence_check/, error.message)
  end

  test "model validation mirrors the exactly-one-amount rule" do
    rule = RecurringTransaction.new(rule_attrs(share_amount: "1.5"))

    assert_not rule.valid?
    assert rule.errors[:share_amount].any?
  end

  test "share-amount mode accepts fractional shares at numeric(20,8) precision" do
    rule = RecurringTransaction.create!(rule_attrs(amount_type: "shares", dollar_amount: nil,
                                                   share_amount: "0.12345678"))
    assert_equal BigDecimal("0.12345678"), rule.reload.share_amount
  end

  test "FK CASCADE: deleting a portfolio removes its recurring rules at the DB level" do
    rule = RecurringTransaction.create!(rule_attrs)

    @portfolio.delete

    assert_not RecurringTransaction.exists?(rule.id)
  end

  test "FK RESTRICT: an instrument referenced by a rule cannot be deleted at the DB level" do
    RecurringTransaction.create!(rule_attrs)

    assert_raises ActiveRecord::InvalidForeignKey do
      @instrument.delete
    end
  end

  test "defaults: active true, consecutive_skips 0, side buy" do
    rule = RecurringTransaction.create!(rule_attrs)
    rule.reload

    assert rule.active
    assert_equal 0, rule.consecutive_skips
    assert_equal "buy", rule.side
  end
end
