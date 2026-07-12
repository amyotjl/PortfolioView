require "test_helper"

# The split-model correctness crux (docs/PLAN.md § Core domain logic /
# § Verification): CSF(i, t, D) = ∏ ratio of splits with t < ex_date ≤ D,
# shares roll FORWARD, a split applies at the START of its ex-date.
class Holdings::CalculatorTest < ActiveSupport::TestCase
  include DomainTestHelper

  # Real AAPL 4:1 split ex-date: Monday 2020-08-31.
  EX_DATE = Date.new(2020, 8, 31)

  setup do
    @portfolio = create_portfolio
    @aapl = create_instrument(symbol: "AAPL")
    create_trading_days(Date.new(2020, 8, 24), Date.new(2020, 9, 4))
    seed_prices(@aapl, {
      Date.new(2020, 8, 27) => "500",   # unadjusted, pre-split
      Date.new(2020, 8, 28) => "499",
      EX_DATE => "134"                  # unadjusted, post-split
    })
    split!(@aapl, on: EX_DATE, ratio: "4")
  end

  def holdings(from:, to:, portfolio: @portfolio, **opts)
    Holdings::Calculator.call(portfolio: portfolio, from: from, to: to, **opts).holdings
  end

  test "PLAN.md fixture: buy 10 AAPL @ $400 pre-split -> CSF 4 -> 40 shares x $134 close = $5,360" do
    buy!(@portfolio, @aapl, on: Date.new(2020, 8, 27), shares: "10", price: "400")

    result = holdings(from: Date.new(2020, 8, 27), to: EX_DATE)

    assert_equal bd("10"), result[Date.new(2020, 8, 27)][@aapl.id]
    assert_equal bd("10"), result[Date.new(2020, 8, 28)][@aapl.id], "no split factor before the ex-date"
    assert_equal bd("40"), result[EX_DATE][@aapl.id], "4:1 split rolls the count forward on the ex-date"
    assert_equal bd("5360"), result[EX_DATE][@aapl.id] * bd("134")
  end

  test "PLAN.md fixture: buy on the ex-date is post-split basis (split applies before same-day transactions)" do
    buy!(@portfolio, @aapl, on: Date.new(2020, 8, 27), shares: "10", price: "400")
    buy!(@portfolio, @aapl, on: EX_DATE, shares: "10", price: "134")

    result = holdings(from: EX_DATE, to: EX_DATE)

    # 10 pre-split shares x 4, plus 10 ex-date shares NOT multiplied.
    assert_equal bd("50"), result[EX_DATE][@aapl.id]
  end

  test "PLAN.md fixture: sell of the full post-split count on the ex-date empties the position" do
    buy!(@portfolio, @aapl, on: Date.new(2020, 8, 27), shares: "10", price: "400")
    sell!(@portfolio, @aapl, on: EX_DATE, shares: "40", price: "134")

    result = holdings(from: Date.new(2020, 8, 28), to: EX_DATE)

    assert_equal bd("10"), result[Date.new(2020, 8, 28)][@aapl.id]
    assert_equal({}, result[EX_DATE], "a position at zero is dropped, not kept as a 0-share key")
  end

  test "CSF compounds across multiple splits after the purchase date" do
    msft = create_instrument(symbol: "MSFT")
    buy!(@portfolio, msft, on: Date.new(2020, 8, 24), shares: "3", price: "100")
    split!(msft, on: Date.new(2020, 8, 26), ratio: "2")
    split!(msft, on: Date.new(2020, 9, 1), ratio: "3")

    result = holdings(from: Date.new(2020, 8, 24), to: Date.new(2020, 9, 1))

    assert_equal bd("3"), result[Date.new(2020, 8, 24)][msft.id]
    assert_equal bd("6"), result[Date.new(2020, 8, 26)][msft.id]
    assert_equal bd("6"), result[Date.new(2020, 8, 31)][msft.id]
    assert_equal bd("18"), result[Date.new(2020, 9, 1)][msft.id]
  end

  test "a weekend-dated transaction surfaces in the next trading day's snapshot" do
    buy!(@portfolio, @aapl, on: Date.new(2020, 8, 29), shares: "5", price: "450") # Saturday

    result = holdings(from: Date.new(2020, 8, 28), to: EX_DATE)

    assert_equal({}, result[Date.new(2020, 8, 28)], "Friday predates the Saturday buy")
    # Saturday buy of 5 shares is pre-split basis: the Monday ex-date multiplies it.
    assert_equal bd("20"), result[EX_DATE][@aapl.id]
  end

  test "transactions after `to` are ignored" do
    buy!(@portfolio, @aapl, on: Date.new(2020, 8, 27), shares: "10", price: "400")
    buy!(@portfolio, @aapl, on: Date.new(2020, 9, 2), shares: "99", price: "130")

    result = holdings(from: Date.new(2020, 8, 27), to: Date.new(2020, 8, 28))

    assert_equal bd("10"), result[Date.new(2020, 8, 28)][@aapl.id]
  end

  test "every trading day in range gets a snapshot key, even before the first transaction" do
    buy!(@portfolio, @aapl, on: Date.new(2020, 8, 27), shares: "10", price: "400")

    result = holdings(from: Date.new(2020, 8, 24), to: Date.new(2020, 8, 28))

    assert_equal weekdays_between(Date.new(2020, 8, 24), Date.new(2020, 8, 28)), result.keys
    assert_equal({}, result[Date.new(2020, 8, 24)])
  end

  test "issues exactly 3 queries: transactions, splits, trading days" do
    buy!(@portfolio, @aapl, on: Date.new(2020, 8, 27), shares: "10", price: "400")
    msft = create_instrument(symbol: "MSFT")
    buy!(@portfolio, msft, on: Date.new(2020, 8, 27), shares: "7", price: "200")
    portfolio = @portfolio # loaded; the service must not touch associations

    queries = count_queries do
      holdings(from: Date.new(2020, 8, 24), to: Date.new(2020, 9, 4), portfolio: portfolio)
    end

    assert_equal 3, queries, "one sweep: transactions + splits + trading days, no N+1"
  end

  test "injected transactions replace the portfolio's stored transactions" do
    buy!(@portfolio, @aapl, on: Date.new(2020, 8, 27), shares: "999", price: "1") # must be ignored

    synthetic = Struct.new(:instrument_id, :side, :shares, :executed_on)
    injected = [ synthetic.new(@aapl.id, "buy", bd("10"), Date.new(2020, 8, 27)) ]

    result = holdings(from: EX_DATE, to: EX_DATE, transactions: injected)

    assert_equal bd("40"), result[EX_DATE][@aapl.id]
  end

  test "all share counts are BigDecimal — never Float" do
    buy!(@portfolio, @aapl, on: Date.new(2020, 8, 27), shares: "0.12345678", price: "400")

    result = holdings(from: Date.new(2020, 8, 27), to: EX_DATE)

    result.each_value do |positions|
      positions.each_value { |shares| assert_instance_of BigDecimal, shares }
    end
    assert_equal bd("0.49382712"), result[EX_DATE][@aapl.id]
  end

  test "a Float share count in injected transactions raises TypeError" do
    synthetic = Struct.new(:instrument_id, :side, :shares, :executed_on)
    injected = [ synthetic.new(@aapl.id, "buy", 10.0, Date.new(2020, 8, 27)) ]

    assert_raises TypeError do
      holdings(from: EX_DATE, to: EX_DATE, transactions: injected)
    end
  end

  test "result and its holdings are frozen" do
    buy!(@portfolio, @aapl, on: Date.new(2020, 8, 27), shares: "10", price: "400")

    result = Holdings::Calculator.call(portfolio: @portfolio, from: EX_DATE, to: EX_DATE)

    assert_predicate result, :frozen?
    assert_predicate result.holdings, :frozen?
    assert_predicate result.holdings[EX_DATE], :frozen?
  end
end
