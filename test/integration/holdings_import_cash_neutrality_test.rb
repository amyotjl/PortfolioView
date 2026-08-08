require "test_helper"

# issue #80, test 11 — THE PROMISE OF THE OFFSETTING DEPOSIT.
#
# A holdings snapshot has no deposit history, so HoldingsCsvParser synthesizes one
# opening buy per position. Under a cash ledger that buy would debit cash the user
# never spent, leaving the portfolio deeply negative. The fix is an offsetting
# `deposit`, same date and same dollars as its buy — and the claim being tested is
# that this is not merely "close enough" but EXACT:
#
#   * cash lands at 0.00, because each deposit cancels its own buy;
#   * net_deposits equals total book value — the same figure the trade basis
#     produced before there was a cash ledger;
#   * every synthetic benchmark trade lands on the SAME DATE for the SAME DOLLARS,
#     so benchmark_return_pct does not move either.
#
# THE CONTROL IS BUILT, NOT HARDCODED. The same file is imported twice; one copy's
# cash rows are then destroyed, which leaves a portfolio byte-identical to what a
# pre-#80 import produced (transactions only, untracked). Every figure is compared
# against that copy. A hardcoded constant would have to be re-derived whenever the
# fixture changed, and re-deriving it from the new code is how a pinning test
# quietly stops pinning anything.
#
# THIS TEST MUST DISCRIMINATE TWO MUTATIONS, not one:
#   1. omitting the offsetting deposits — caught by cash_balance/deposit_basis;
#   2. DATING THEM ONE DAY OFF — which still leaves cash at 0.00 at the end of the
#      sweep, so a cash-only assertion passes, but moves the benchmark's synthetic
#      fill onto a different close and changes benchmark_return_pct (and, because
#      the balance is briefly negative for a day, max_drawdown_pct too).
# SPY's closes therefore have to VARY day to day, or mutation 2 is invisible.
class HoldingsImportCashNeutralityTest < ActionDispatch::IntegrationTest
  include DomainTestHelper

  AS_OF = Date.new(2026, 3, 4).freeze

  setup do
    @with_cash = users(:one)
    @control   = users(:two)

    # A rising SPY, so a fill one day later is a DIFFERENT fill. A flat calendar
    # would make mutation 2 undetectable and this test half a test.
    days = weekdays_between(Date.new(2026, 2, 2), Date.new(2026, 3, 31))
    @spy = create_trading_days(Date.new(2026, 2, 2), Date.new(2026, 3, 31),
                              closes: days.each_with_index.to_h { |day, i| [ day, 400 + i ] })
    @benchmark = ::Benchmark.create!(instrument: @spy, name: "S&P 500 (SPY)")

    assert_operator close_on(AS_OF), :!=, close_on(AS_OF + 1),
                    "SPY must move between these two days or mutation 2 cannot be seen"
  end

  def close_on(date) = DailyPrice.find_by!(instrument: @spy, date: date).close

  def import_holdings!(user)
    document = Portfolios::Transfer::HoldingsCsvParser.call(file_fixture("holdings_report.csv").read)
    result = Portfolios::Transfer::Import.call(user: user, document: document)
    assert_equal 0, result.totals[:portfolios_failed], result.portfolios.map(&:errors).inspect

    user.portfolios.each do |portfolio|
      portfolio.update!(benchmark: @benchmark)
      # The imported listings are CAD and have no provider coverage, so give them
      # a price here — otherwise every portfolio values at zero and the assertions
      # would agree trivially.
      portfolio.transactions.map(&:instrument).uniq.each do |instrument|
        seed_prices(instrument, weekdays_between(Date.new(2026, 2, 2), Date.new(2026, 3, 31)).index_with { 50 })
      end
    end

    result
  end

  def summaries
    with_cash = import_holdings!(@with_cash)
    import_holdings!(@control)
    # Exactly what a pre-#80 import left behind: the trades, and nothing else.
    CashTransaction.where(portfolio: @control.portfolios).destroy_all

    [ with_cash,
      Portfolios::Summary.call(portfolio: @with_cash.portfolios.find_by!(name: "TFSA")),
      Portfolios::Summary.call(portfolio: @control.portfolios.find_by!(name: "TFSA")) ]
  end

  test "one offsetting deposit per synthesized buy, same day, same dollars" do
    result = import_holdings!(@with_cash)

    tfsa = @with_cash.portfolios.find_by!(name: "TFSA")
    assert_equal tfsa.transactions.count, tfsa.cash_transactions.count,
                 "one deposit per synthesized buy, or the balance cannot be zero"
    assert_equal 4, result.portfolios.find { |p| p.name == "TFSA" }.cash_created
    assert_equal [ "deposit" ], tfsa.cash_transactions.distinct.pluck(:kind)
    assert_equal [ AS_OF ], tfsa.cash_transactions.distinct.pluck(:occurred_on)

    # Each deposit equals what TradeCash charges for its own buy, to the cent.
    expected = tfsa.transactions.map { |tx| Portfolios::TradeCash.for(tx) }.sort
    assert_equal expected, tfsa.cash_transactions.map(&:amount).sort
  end

  test "the snapshot's cash balance is EXACTLY zero, not merely close" do
    _result, cash_summary, _control = summaries

    assert_equal "cash", cash_summary.deposit_basis, "the basis does flip — that part is not a no-op"
    assert_not_nil cash_summary.cash_balance
    assert_equal BigDecimal(0), cash_summary.cash_balance
    assert cash_summary.cash_balance.zero?, "not 'within a cent of zero' — exactly zero"
    assert_not cash_summary.cash_negative, "the balance never dips below zero on a same-day offset"
    assert_nil cash_summary.cash_negative_since
  end

  test "net_deposits equals total book value, the same figure the trade basis produced" do
    _result, cash_summary, control = summaries

    assert_equal "trades", control.deposit_basis
    assert_equal control.net_deposits, cash_summary.net_deposits
    assert_operator cash_summary.net_deposits, :>, 0, "a zero denominator would make this vacuous"

    book_value = @with_cash.portfolios.find_by!(name: "TFSA")
                           .transactions.sum { |tx| Portfolios::TradeCash.for(tx) }
    assert_equal book_value, cash_summary.net_deposits
  end

  test "benchmark_return_pct does not move, because every synthetic fill is unchanged" do
    # The mutation this exists for: a deposit dated one day off leaves cash at zero
    # and net_deposits unchanged, but feeds the shadow ETF on a different day at a
    # different close. Nothing else in the suite would notice.
    _result, cash_summary, control = summaries

    assert_not_nil control.benchmark_return_pct, "without a benchmark this test is vacuous"
    assert_equal control.benchmark_return_pct, cash_summary.benchmark_return_pct
    assert_equal control.vs_benchmark_edge_pct, cash_summary.vs_benchmark_edge_pct
  end

  test "every other lifetime figure is identical too" do
    _result, cash_summary, control = summaries

    assert_equal control.current_value, cash_summary.current_value
    assert_equal control.holdings_value, cash_summary.holdings_value
    assert_equal control.current_value, cash_summary.holdings_value,
                 "holdings + a zero balance is holdings"
    assert_equal control.total_return, cash_summary.total_return
    assert_equal control.total_return_pct, cash_summary.total_return_pct
    # Cash-inclusive drawdown equals holdings-only drawdown precisely because the
    # balance is zero on every swept day, including the day of the buys.
    assert_equal control.max_drawdown_pct, cash_summary.max_drawdown_pct
    assert_equal control.as_of, cash_summary.as_of
  end
end
