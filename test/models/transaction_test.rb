require "test_helper"

class TransactionTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email_address: "trader@example.com", password: "password")
    @portfolio = Portfolio.create!(user: @user, name: "Main")
    @instrument = Instrument.create!(symbol: "AAPL", instrument_type: "stock")
    @rule = RecurringTransaction.create!(
      portfolio: @portfolio, instrument: @instrument,
      side: "buy", amount_type: "dollars", dollar_amount: "500.00",
      frequency: "monthly", anchor_on: Date.new(2026, 1, 31), next_run_on: Date.new(2026, 8, 31)
    )
  end

  def transaction_attrs(overrides = {})
    {
      portfolio: @portfolio, instrument: @instrument,
      side: "buy", kind: "normal",
      shares: "2.5", price: "200.123456", fees: "1.00",
      executed_on: Date.new(2026, 7, 10)
    }.merge(overrides)
  end

  test "partial UNIQUE (recurring_transaction_id, scheduled_for) rejects a duplicate slot at the DB level" do
    slot = Date.new(2026, 7, 31)
    Transaction.create!(transaction_attrs(recurring_transaction: @rule, scheduled_for: slot))

    assert_raises ActiveRecord::RecordNotUnique do
      Transaction.new(transaction_attrs(recurring_transaction: @rule, scheduled_for: slot))
                 .save!(validate: false)
    end
  end

  test "partial index does not constrain manual transactions (NULL recurring_transaction_id)" do
    slot = Date.new(2026, 7, 31)

    assert_nothing_raised do
      2.times { Transaction.create!(transaction_attrs(scheduled_for: slot)) }
    end
  end

  test "model validation mirrors the materialization idempotency guard" do
    slot = Date.new(2026, 7, 31)
    Transaction.create!(transaction_attrs(recurring_transaction: @rule, scheduled_for: slot))
    duplicate = Transaction.new(transaction_attrs(recurring_transaction: @rule, scheduled_for: slot))

    assert_not duplicate.valid?
    assert duplicate.errors[:scheduled_for].any?
  end

  test "CHECK rejects shares <= 0 at the DB level" do
    error = assert_raises ActiveRecord::StatementInvalid do
      Transaction.new(transaction_attrs(shares: 0)).save!(validate: false)
    end
    assert_match(/transactions_shares_positive/, error.message)
  end

  test "CHECK rejects a negative fee at the DB level" do
    error = assert_raises ActiveRecord::StatementInvalid do
      Transaction.new(transaction_attrs(fees: "-1.00")).save!(validate: false)
    end
    assert_match(/transactions_fees_nonnegative/, error.message)
  end

  test "CHECK rejects an unknown side at the DB level" do
    error = assert_raises ActiveRecord::StatementInvalid do
      Transaction.new(transaction_attrs(side: "short")).save!(validate: false)
    end
    assert_match(/transactions_side_check/, error.message)
  end

  test "FK RESTRICT: an instrument with recorded trades cannot be deleted at the DB level" do
    Transaction.create!(transaction_attrs)

    assert_raises ActiveRecord::InvalidForeignKey do
      @instrument.delete
    end
  end

  test "FK NULLIFY: deleting a recurring rule keeps its materialized trades" do
    trade = Transaction.create!(transaction_attrs(recurring_transaction: @rule,
                                                  scheduled_for: Date.new(2026, 7, 31)))

    # `delete` bypasses the model's dependent: :nullify, proving the DB's
    # ON DELETE SET NULL itself.
    @rule.delete

    assert Transaction.exists?(trade.id), "materialized trade must survive rule deletion"
    assert_nil trade.reload.recurring_transaction_id
  end

  test "FK CASCADE: deleting a user removes portfolios and their transactions at the DB level" do
    trade = Transaction.create!(transaction_attrs)

    @user.delete

    assert_not Transaction.exists?(trade.id)
    assert_not Portfolio.exists?(@portfolio.id)
  end

  test "shares and price keep their full numeric precision" do
    trade = Transaction.create!(transaction_attrs(shares: "0.00000001", price: "1234567890.123456"))

    assert_equal BigDecimal("0.00000001"), trade.reload.shares
    assert_equal BigDecimal("1234567890.123456"), trade.reload.price
  end
end
