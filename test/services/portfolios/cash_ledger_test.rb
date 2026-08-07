require "test_helper"

# The liquid-cash balance series (issue #80): end-of-day balances, the
# external/internal kind split, splits and DRIPs leaving cash alone, and the
# unbucketed flag that keeps unplaceable money from being silently lost.
class Portfolios::CashLedgerTest < ActiveSupport::TestCase
  include DomainTestHelper

  MON = Date.new(2026, 7, 6)
  TUE = Date.new(2026, 7, 7)
  WED = Date.new(2026, 7, 8)
  THU = Date.new(2026, 7, 9)
  FRI = Date.new(2026, 7, 10)

  setup do
    @portfolio = create_portfolio
    create_trading_days(MON, FRI)
    @aapl = create_instrument(symbol: "AAPL")
    seed_prices(@aapl, { MON => "500", TUE => "500", WED => "600", THU => "600", FRI => "600" })
  end

  def ledger(to: FRI, days: nil, portfolio: @portfolio)
    Portfolios::CashLedger.call(
      rows: Portfolios::CashLedger.rows_for(portfolio),
      days: days || Trading::Calendar.days_between(MON, to),
      transactions: portfolio.transactions.order(:executed_on, :id).to_a,
      to: to
    )
  end

  # ---------------------------------------------------------------------------
  # The balance formula, fees on BOTH sides — hand-computed, 6 rows.
  #
  #   MON  deposit    +10,000.00                        -> 10,000.00
  #   TUE  BUY  10 AAPL @ 500, fees 4.95   -5,004.95    ->  4,995.05
  #   WED  SELL  4 AAPL @ 600, fees 6.95   +2,393.05
  #        interest                            +1.25    ->  7,389.35
  #   THU  fee                               -4.95      ->  7,384.40
  #   FRI  withdrawal                     -2,000.00     ->  5,384.40
  # ---------------------------------------------------------------------------
  def six_row_fixture
    cash!(@portfolio, kind: "deposit", amount: "10000.00", on: MON)
    buy!(@portfolio, @aapl, on: TUE, shares: "10", price: "500", fees: "4.95")
    sell!(@portfolio, @aapl, on: WED, shares: "4", price: "600", fees: "6.95")
    cash!(@portfolio, kind: "interest", amount: "1.25", on: WED)
    cash!(@portfolio, kind: "fee", amount: "-4.95", on: THU)
    cash!(@portfolio, kind: "withdrawal", amount: "-2000.00", on: FRI)
  end

  test "balances are end-of-day and net a buy's fees IN and a sell's fees OUT" do
    six_row_fixture

    balances = ledger.balances

    assert_equal bd("10000.00"), balances[MON]
    assert_equal bd("4995.05"),  balances[TUE], "a buy debits cost PLUS its fee"
    assert_equal bd("7389.35"),  balances[WED], "a sell credits proceeds MINUS its fee, plus the interest"
    assert_equal bd("7384.40"),  balances[THU]
    assert_equal bd("5384.40"),  balances[FRI]
    assert_equal bd("5384.40"),  ledger.closing_balance
  end

  # The exact generalization of the DRIP rule: interest/dividend_cash/tax/fee move
  # the BALANCE but are not contributions — the broker moved that money INSIDE the
  # account. Adding any of the four to EXTERNAL_KINDS would silently turn a broker
  # dividend into a user contribution and understate return.
  test "only deposits and withdrawals are external; the four internal kinds move the balance alone" do
    six_row_fixture

    result = ledger

    assert_equal bd("8000.00"), result.net_external_total, "10,000 deposited - 2,000 withdrawn"
    assert_equal [ MON, FRI ], result.external_by_date.keys.sort,
                 "the WED interest and THU fee are NOT external cash"
    assert_equal %w[deposit], result.external_by_date.fetch(MON).map(&:kind)
    assert_equal %w[withdrawal], result.external_by_date.fetch(FRI).map(&:kind)
    # ...but they are unmistakably in the balance: 7,389.35 includes the 1.25.
    assert_equal bd("7389.35"), result.balances[WED]
  end

  test "a portfolio with no cash rows is UNTRACKED, and every member is empty" do
    buy!(@portfolio, @aapl, on: MON, shares: "1", price: "500")

    result = ledger

    assert_not result.tracked
    assert_empty result.balances
    assert_equal bd("0"), result.closing_balance
    assert_equal bd("0"), result.net_external_total
    assert_nil result.first_negative_on
    assert_not result.unbucketed
    assert_same Portfolios::CashLedger::UNTRACKED, result
  end

  # --- negative cash: reported, never rejected ------------------------------

  test "a buy that overdraws the account reports the day it went negative" do
    cash!(@portfolio, kind: "deposit", amount: "100.00", on: MON)
    buy!(@portfolio, @aapl, on: TUE, shares: "1", price: "500")

    result = ledger

    assert_equal bd("-400.00"), result.closing_balance
    assert_equal TUE, result.first_negative_on
    assert_equal bd("-400.00"), result.min_balance
  end

  test "min_balance remembers the dip even when the portfolio ends positive" do
    cash!(@portfolio, kind: "deposit", amount: "100.00", on: MON)
    buy!(@portfolio, @aapl, on: TUE, shares: "1", price: "500")          # -400
    cash!(@portfolio, kind: "deposit", amount: "5000.00", on: THU)       # +4600

    result = ledger

    assert_equal bd("4600.00"), result.closing_balance
    assert_equal bd("-400.00"), result.min_balance, "the dip is what the warning is about"
    assert_equal TUE, result.first_negative_on
  end

  # Per-transaction cent rounding is what makes this land on exactly zero:
  # 0.33333333 x 300 = 99.999999, rounded to 100.00 against the 100.00 deposit.
  # Rounding late would leave a +0.000001 residual instead.
  test "a sub-cent trade product cannot leave a residual, so a flat account reports exactly zero" do
    cash!(@portfolio, kind: "deposit", amount: "100.00", on: MON)
    seed_prices(@aapl, { TUE => "300" })
    buy!(@portfolio, @aapl, on: TUE, shares: "0.33333333", price: "300")

    result = ledger

    assert_equal bd("0"), result.closing_balance, "100.00 deposited, 100.00 spent — exactly flat"
    assert_predicate result.closing_balance, :zero?
    assert_nil result.first_negative_on, "an exactly flat account is not negative"
  end

  # --- what must NOT move cash ----------------------------------------------

  test "a split does not move cash" do
    cash!(@portfolio, kind: "deposit", amount: "10000.00", on: MON)
    buy!(@portfolio, @aapl, on: MON, shares: "10", price: "500")
    split!(@aapl, on: WED, ratio: "4")

    balances = ledger.balances

    assert_equal bd("5000.00"), balances[TUE]
    assert_equal bd("5000.00"), balances[WED], "the ex-date moves shares, not money"
    assert_equal bd("5000.00"), balances[FRI]
  end

  test "a dividend_reinvestment buy does not move cash" do
    cash!(@portfolio, kind: "deposit", amount: "10000.00", on: MON)
    buy!(@portfolio, @aapl, on: TUE, shares: "1", price: "500", kind: "dividend_reinvestment")

    assert_equal bd("10000.00"), ledger.closing_balance,
                 "a DRIP is internal compounding — debiting it would drain the balance with no matching credit"
  end

  # --- bucketing ------------------------------------------------------------

  test "a weekend movement takes effect on the next trading day" do
    cash!(@portfolio, kind: "deposit", amount: "500.00", on: Date.new(2026, 7, 5)) # Sunday

    balances = ledger.balances

    assert_equal bd("500.00"), balances[MON]
    assert_equal [ MON ], ledger.external_by_date.keys
  end

  # Kills the silent `next if effective.nil?` drop: for a trade, losing the flow
  # is tolerable (the position is what matters); for cash it loses MONEY.
  test "cash the trading calendar cannot place yet is flagged unbucketed, never silently dropped" do
    cash!(@portfolio, kind: "deposit", amount: "500.00", on: MON)
    # SPY has no row for the following Monday, so this deposit has no effective day.
    beyond = Date.new(2026, 7, 13)
    cash!(@portfolio, kind: "deposit", amount: "7500.00", on: beyond)

    result = ledger(to: beyond)

    assert result.unbucketed, "unplaceable cash must be reported so meta[:partial] can carry it"
    assert_equal bd("500.00"), result.closing_balance, "and it is NOT in any day's balance"
  end

  test "a movement dated after the window is neither counted nor reported as unbucketed" do
    cash!(@portfolio, kind: "deposit", amount: "500.00", on: MON)
    cash!(@portfolio, kind: "deposit", amount: "7500.00", on: FRI)

    result = ledger(to: WED)

    assert_not result.unbucketed, "a later window's movement is not this window's missing money"
    assert_equal bd("500.00"), result.closing_balance
  end

  # --- query budget ---------------------------------------------------------

  test "rows_for is exactly one query and the sweep itself is pure" do
    six_row_fixture
    rows = nil
    days = Trading::Calendar.days_between(MON, FRI)
    txs = @portfolio.transactions.order(:executed_on, :id).to_a

    load_queries = count_queries { rows = Portfolios::CashLedger.rows_for(@portfolio) }
    sweep_queries = count_queries do
      Portfolios::CashLedger.call(rows: rows, days: days, transactions: txs, to: FRI)
    end

    assert_equal 1, load_queries, "the cash rows are ONE query added to a valuation"
    assert_equal 0, sweep_queries, "the sweep must not re-derive the trading calendar"
  end

  test "for_portfolio derives the same ledger standalone, without a price sweep" do
    six_row_fixture

    standalone = Portfolios::CashLedger.for_portfolio(@portfolio)

    expected = ledger

    assert_equal expected.closing_balance, standalone.closing_balance
    assert_equal expected.balances, standalone.balances
    assert_equal expected.net_external_total, standalone.net_external_total
    assert_nil expected.first_negative_on, "this fixture never goes negative"
    assert_nil standalone.first_negative_on
  end
end
