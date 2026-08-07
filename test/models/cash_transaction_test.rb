require "test_helper"

class CashTransactionTest < ActiveSupport::TestCase
  # A sign that satisfies cash_transactions_amount_sign for each kind.
  VALID_AMOUNTS = {
    "deposit" => "500.00", "withdrawal" => "-500.00",
    "interest" => "1.25", "dividend_cash" => "12.34",
    "tax" => "-3.50", "fee" => "-4.95"
  }.freeze

  setup do
    @user = User.create!(email_address: "cash-owner@example.com", password: "password")
    @portfolio = Portfolio.create!(user: @user, name: "Main")
  end

  def cash_attrs(overrides = {})
    {
      portfolio: @portfolio, kind: "deposit", amount: "1000.00",
      occurred_on: Date.new(2026, 7, 10)
    }.merge(overrides)
  end

  test "every one of the six kinds saves with a valid sign" do
    assert_equal VALID_AMOUNTS.keys.sort, CashTransaction::KINDS.sort,
                 "this test must cover exactly the kinds the model declares"

    CashTransaction::KINDS.each do |kind|
      amount = VALID_AMOUNTS.fetch(kind)
      row = CashTransaction.create!(cash_attrs(kind: kind, amount: amount))

      assert_equal BigDecimal(amount), row.reload.amount, "#{kind} must persist its amount"
    end

    assert_equal CashTransaction::KINDS.size, @portfolio.cash_transactions.count
  end

  test "the four internal kinds accept either sign (a dividend reversal, a tax refund)" do
    assert_nothing_raised do
      CashTransaction.create!(cash_attrs(kind: "dividend_cash", amount: "-12.34"))
      CashTransaction.create!(cash_attrs(kind: "tax", amount: "3.50"))
      CashTransaction.create!(cash_attrs(kind: "fee", amount: "4.95"))
      CashTransaction.create!(cash_attrs(kind: "interest", amount: "-0.02"))
    end
  end

  test "model validation rejects a negative deposit" do
    row = CashTransaction.new(cash_attrs(kind: "deposit", amount: "-500.00"))

    assert_not row.valid?
    assert row.errors[:amount].any?
  end

  test "CHECK rejects a negative deposit at the DB level" do
    error = assert_raises ActiveRecord::StatementInvalid do
      CashTransaction.new(cash_attrs(kind: "deposit", amount: "-500.00")).save!(validate: false)
    end
    assert_match(/cash_transactions_amount_sign/, error.message)
  end

  test "model validation rejects a positive withdrawal" do
    row = CashTransaction.new(cash_attrs(kind: "withdrawal", amount: "500.00"))

    assert_not row.valid?
    assert row.errors[:amount].any?
  end

  test "CHECK rejects a positive withdrawal at the DB level" do
    error = assert_raises ActiveRecord::StatementInvalid do
      CashTransaction.new(cash_attrs(kind: "withdrawal", amount: "500.00")).save!(validate: false)
    end
    assert_match(/cash_transactions_amount_sign/, error.message)
  end

  test "model validation rejects a zero amount for every kind" do
    CashTransaction::KINDS.each do |kind|
      row = CashTransaction.new(cash_attrs(kind: kind, amount: "0.00"))

      assert_not row.valid?, "#{kind} with amount 0 must be invalid"
      assert row.errors[:amount].any?, "#{kind} with amount 0 must key its error on :amount"
    end
  end

  test "CHECK rejects a zero amount for every kind at the DB level" do
    CashTransaction::KINDS.each do |kind|
      error = assert_raises(ActiveRecord::StatementInvalid,
                            "#{kind} with amount 0 must violate the CHECK") do
        CashTransaction.new(cash_attrs(kind: kind, amount: "0.00")).save!(validate: false)
      end
      assert_match(/cash_transactions_amount_sign/, error.message)
    end
  end

  test "model validation rejects an unknown kind" do
    row = CashTransaction.new(cash_attrs(kind: "bonus", amount: "10.00"))

    assert_not row.valid?
    assert row.errors[:kind].any?
  end

  test "CHECK rejects an unknown kind at the DB level" do
    error = assert_raises ActiveRecord::StatementInvalid do
      CashTransaction.new(cash_attrs(kind: "bonus", amount: "10.00")).save!(validate: false)
    end
    assert_match(/cash_transactions_kind_check/, error.message)
  end

  # Pinned deliberately. Interest, dividend_cash, tax and fee move the BALANCE
  # but are not contributions; adding any of them to EXTERNAL_KINDS would
  # silently turn a broker dividend into a user contribution, inflating
  # net_deposits and understating return with no error anywhere.
  test "EXTERNAL_KINDS is exactly deposit and withdrawal" do
    assert_equal %w[deposit withdrawal], CashTransaction::EXTERNAL_KINDS
    assert_equal %w[interest dividend_cash tax fee],
                 CashTransaction::KINDS - CashTransaction::EXTERNAL_KINDS
  end

  test "FK CASCADE: deleting a portfolio removes its cash rows at the DB level" do
    row = CashTransaction.create!(cash_attrs)

    # `delete` bypasses any model-level dependent: option — and there is
    # deliberately none on the has_many — so this proves the DB's ON DELETE
    # CASCADE itself.
    @portfolio.delete

    assert_not CashTransaction.exists?(row.id)
  end

  test "creating a cash row bumps the portfolio's series_version" do
    before = @portfolio.reload.series_version

    CashTransaction.create!(cash_attrs)

    assert_equal before + 1, @portfolio.reload.series_version
  end

  test "updating a cash row bumps the portfolio's series_version" do
    row = CashTransaction.create!(cash_attrs)
    before = @portfolio.reload.series_version

    row.update!(amount: "750.00")

    assert_equal before + 1, @portfolio.reload.series_version
  end

  test "destroying a cash row bumps the portfolio's series_version" do
    row = CashTransaction.create!(cash_attrs)
    before = @portfolio.reload.series_version

    row.destroy!

    assert_equal before + 1, @portfolio.reload.series_version
  end

  test "moving a cash row between portfolios bumps both series_versions" do
    other = Portfolio.create!(user: @user, name: "Other")
    row = CashTransaction.create!(cash_attrs)
    before_main = @portfolio.reload.series_version
    before_other = other.reload.series_version

    row.update!(portfolio: other)

    assert_equal before_main + 1, @portfolio.reload.series_version
    assert_equal before_other + 1, other.reload.series_version
  end

  test "cash_tracked? is false with no rows, true with one, and false again once the last is gone" do
    assert_not @portfolio.cash_tracked?

    row = CashTransaction.create!(cash_attrs)
    assert @portfolio.cash_tracked?

    row.destroy!
    assert_not @portfolio.cash_tracked?
  end

  # The mechanized form of the owner's decision: negative cash is SHOWN with a
  # warning, never rejected. If a balance validation is ever added — at the
  # model, in a CHECK or as a clamp — this test fails loudly.
  test "a withdrawal that drives the balance deeply negative still saves" do
    CashTransaction.create!(cash_attrs(kind: "deposit", amount: "100.00"))
    row = CashTransaction.new(cash_attrs(kind: "withdrawal", amount: "-50000.00",
                                         occurred_on: Date.new(2026, 7, 11)))

    assert row.valid?, "a balance-driving-negative withdrawal must be valid: #{row.errors.full_messages}"
    assert_nothing_raised { row.save! }

    assert row.persisted?
    assert_equal BigDecimal("-49900.00"), @portfolio.cash_transactions.sum(:amount)
  end

  test "amount keeps its exact cent precision" do
    row = CashTransaction.create!(cash_attrs(amount: "1234567890.12"))

    assert_equal BigDecimal("1234567890.12"), row.reload.amount
  end
end
