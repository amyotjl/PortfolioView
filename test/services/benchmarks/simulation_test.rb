require "test_helper"

# Cash-flow-matched benchmark (docs/PLAN.md § Core domain logic /
# § Verification): same-dollar synthetic trades at the next available
# benchmark close, DRIP excluded, clamps flagged, price-return labeled.
class Benchmarks::SimulationTest < ActiveSupport::TestCase
  include DomainTestHelper

  MON = Date.new(2026, 7, 6)
  TUE = Date.new(2026, 7, 7)
  WED = Date.new(2026, 7, 8)
  THU = Date.new(2026, 7, 9)
  FRI = Date.new(2026, 7, 10)

  setup do
    # SPY is both the trading calendar and the benchmark ETF.
    @spy = create_trading_days(MON, FRI, closes: { MON => "50", TUE => "60", WED => "60", THU => "60", FRI => "60" })
    @benchmark = ::Benchmark.create!(name: "S&P 500", instrument: @spy)
    @portfolio = create_portfolio(benchmark: @benchmark)
    @aapl = create_instrument(symbol: "AAPL")
  end

  def simulate(from: MON, to: FRI, **opts)
    Benchmarks::Simulation.call(portfolio: @portfolio, from: from, to: to, **opts)
  end

  def value_on(result, date)
    result.values.find { |point| point.date == date }&.value
  end

  test "PLAN.md fixture: a buy converts its exact dollars INCLUDING fees at that day's benchmark close" do
    buy!(@portfolio, @aapl, on: MON, shares: "10", price: "100", fees: "5")

    result = simulate

    # $1,005 / $50 close = 20.1 SPY shares -> worth exactly $1,005 on MON.
    assert_equal bd("1005"), value_on(result, MON)
    assert_equal bd("1206"), value_on(result, TUE), "20.1 shares x \$60"
  end

  test "PLAN.md fixture: a sell withdraws its dollars NET of fees" do
    buy!(@portfolio, @aapl, on: MON, shares: "10", price: "100", fees: "5")
    sell!(@portfolio, @aapl, on: TUE, shares: "5", price: "120", fees: "3")

    result = simulate

    # 5 x 120 - 3 = $597 withdrawn at TUE's $60 close -> 9.95 shares sold.
    # 20.1 - 9.95 = 10.15 shares x $60 = $609.
    assert_equal bd("609"), value_on(result, TUE)
    assert_not result.meta[:benchmark_clamped]
  end

  test "a weekend transaction fills at the NEXT trading day's close" do
    create_trading_days(Date.new(2026, 7, 13), Date.new(2026, 7, 13), closes: { Date.new(2026, 7, 13) => "40" })
    buy!(@portfolio, @aapl, on: Date.new(2026, 7, 11), shares: "1", price: "80") # Saturday

    result = simulate(to: Date.new(2026, 7, 13))

    assert_nil value_on(result, FRI), "nothing is invested before the fill"
    assert_equal bd("80"), value_on(result, Date.new(2026, 7, 13)), "\$80 filled at Monday's \$40 close"
  end

  test "PLAN.md fixture: dividend_reinvestment transactions are excluded from benchmark matching" do
    buy!(@portfolio, @aapl, on: MON, shares: "1", price: "100")
    buy!(@portfolio, @aapl, on: TUE, shares: "0.5", price: "100", kind: "dividend_reinvestment")

    result = simulate

    # Only the $100 MON buy is matched: 2 shares x $60 on TUE. A matched DRIP
    # would have handed the shadow position free money here.
    assert_equal bd("120"), value_on(result, TUE)
  end

  test "an over-withdrawal clamps the shadow position at zero and flags meta.benchmark_clamped" do
    buy!(@portfolio, @aapl, on: MON, shares: "1", price: "100")
    sell!(@portfolio, @aapl, on: TUE, shares: "1", price: "300")

    result = simulate

    # $100 buys 2 SPY shares; the $300 withdrawal wants 5 -> clamped to 2.
    assert result.meta[:benchmark_clamped]
    assert_equal bd("0"), value_on(result, TUE)
    assert_equal bd("0"), value_on(result, FRI)
  end

  test "benchmark history shorter than the portfolio clamps the sim start with a meta flag" do
    qqq = create_instrument(symbol: "QQQ", instrument_type: "etf")
    seed_prices(qqq, { WED => "100", THU => "100", FRI => "100" }) # no data before WED
    other_benchmark = ::Benchmark.create!(name: "Nasdaq 100", instrument: qqq)
    buy!(@portfolio, @aapl, on: MON, shares: "2", price: "100")

    result = simulate(benchmark: other_benchmark)

    assert result.meta[:sim_start_clamped]
    assert_nil value_on(result, MON), "no benchmark value before its history starts"
    assert_equal bd("200"), value_on(result, WED), "the MON \$200 fills at QQQ's first available close"
  end

  test "benchmark splits are handled by the shared CSF machinery (value continuity)" do
    # SPY 2:1 split on WED: unadjusted close halves 60 -> 30.
    seed_prices(@spy, { WED => "30", THU => "30", FRI => "30" })
    split!(@spy, on: WED, ratio: "2")
    buy!(@portfolio, @aapl, on: TUE, shares: "1", price: "120")

    result = simulate

    # $120 buys 2 SPY @ $60 TUE; on WED the split doubles them: 4 x $30 = $120.
    assert_equal bd("120"), value_on(result, TUE)
    assert_equal bd("120"), value_on(result, WED), "no phantom jump or crash across the ex-date"
  end

  test "a sell filling on a split ex-date sells post-split shares (split before same-day fills)" do
    seed_prices(@spy, { WED => "30", THU => "30", FRI => "30" })
    split!(@spy, on: WED, ratio: "2")
    buy!(@portfolio, @aapl, on: TUE, shares: "1", price: "120")   # 2 SPY @ 60
    sell!(@portfolio, @aapl, on: WED, shares: "1", price: "120")  # $120 out at $30 close = 4 shares

    result = simulate

    assert_equal bd("0"), value_on(result, WED), "all 4 post-split shares sold, nothing clamped"
    assert_not result.meta[:benchmark_clamped]
  end

  test "a transaction with no benchmark close on or after it is dropped and flags meta.partial" do
    buy!(@portfolio, @aapl, on: MON, shares: "1", price: "100")
    buy!(@portfolio, @aapl, on: Date.new(2026, 7, 12), shares: "1", price: "100") # beyond SPY data

    result = simulate(to: Date.new(2026, 7, 12))

    assert result.meta[:partial]
    assert_equal bd("120"), value_on(result, FRI), "the fillable trade still simulates"
  end

  test "output is labeled price-return" do
    assert_equal "price_return", simulate.meta[:return_basis]
  end

  test "no external transactions yields an empty value series" do
    buy!(@portfolio, @aapl, on: MON, shares: "1", price: "100", kind: "dividend_reinvestment")

    result = simulate

    assert_empty result.values
    assert_not result.meta[:benchmark_clamped]
  end

  test "raises without a benchmark" do
    bare = create_portfolio(name: "No benchmark")

    assert_raises(ArgumentError) do
      Benchmarks::Simulation.call(portfolio: bare, from: MON, to: FRI)
    end
  end

  test "values are BigDecimal and the result is frozen" do
    buy!(@portfolio, @aapl, on: MON, shares: "3", price: "33.333333", fees: "0.01")

    result = simulate

    result.values.each { |point| assert_instance_of BigDecimal, point.value }
    assert_predicate result, :frozen?
    assert_predicate result.values, :frozen?
    assert_predicate result.meta, :frozen?
  end

  # --- basis: deposits for a cash-tracked portfolio (issue #80) --------------

  # THE test that keeps benchmark_return_pct meaningful. summary.rb computes
  #   pct(sim.values.last.value - net_deposits, net_deposits)
  # so the dollars fed to the shadow ETF must be the SAME dollars net_deposits
  # counts. Keep matching trades while the denominator switches to deposits and
  # the expression is off by (Sum trade cost - Sum deposits) — silently, with no
  # flag and no null.
  test "a cash-tracked portfolio matches DEPOSITS, not trades" do
    cash!(@portfolio, kind: "deposit", amount: "1000.00", on: MON)   # SPY @ 50 -> 20 shares
    buy!(@portfolio, @aapl, on: WED, shares: "5", price: "100")      # would be $500 -> 8.333 shares

    result = simulate

    # 20 SPY shares from the deposit alone: 20 x 60 = 1200 from TUE on. Matching
    # the WED trade instead would give a different number on every day.
    assert_equal bd("1000"), value_on(result, MON)
    assert_equal bd("1200"), value_on(result, TUE)
    assert_equal bd("1200"), value_on(result, WED), "the trade is an internal transfer, not a new dollar"
    assert_equal bd("1200"), value_on(result, FRI)
  end

  test "a withdrawal sells the shadow position by its own dollars" do
    cash!(@portfolio, kind: "deposit", amount: "1000.00", on: MON)      # 20 SPY @ 50
    cash!(@portfolio, kind: "withdrawal", amount: "-600.00", on: TUE)   # -10 SPY @ 60

    result = simulate

    assert_equal bd("600"), value_on(result, TUE), "20 - 10 = 10 shares x \$60"
    assert_equal bd("600"), value_on(result, FRI)
    assert_not result.meta[:benchmark_clamped]
  end

  # The DRIP rule generalized: interest/dividend_cash/tax/fee move the balance but
  # are money the broker moved INSIDE the account, so matching them would hand the
  # shadow portfolio free money the benchmark side never models.
  test "the four internal cash kinds are NOT matched into the shadow ETF" do
    cash!(@portfolio, kind: "deposit", amount: "1000.00", on: MON)
    cash!(@portfolio, kind: "interest", amount: "50.00", on: TUE)
    cash!(@portfolio, kind: "dividend_cash", amount: "25.00", on: TUE)
    cash!(@portfolio, kind: "tax", amount: "-5.00", on: TUE)
    cash!(@portfolio, kind: "fee", amount: "-4.95", on: TUE)

    result = simulate

    assert_equal bd("1200"), value_on(result, TUE), "still exactly the 20 deposit-bought shares"
  end

  # Kills include_cash: true in the inner Valuation call: the shadow ETF's value
  # line must be pure benchmark shares, never the user's cash balance.
  test "the user's cash balance never enters the shadow ETF's value line" do
    cash!(@portfolio, kind: "deposit", amount: "1000.00", on: MON)

    result = simulate

    # $1,000 sat as cash all week; the shadow line is 20 SPY shares priced daily.
    # If the inner valuation inherited the cash, MON would read 2,000 and TUE 2,200.
    assert_equal bd("1000"), value_on(result, MON)
    assert_equal bd("1200"), value_on(result, TUE)
  end

  test "a cash-tracked portfolio with only internal kinds matches nothing at all" do
    cash!(@portfolio, kind: "interest", amount: "50.00", on: MON)
    buy!(@portfolio, @aapl, on: MON, shares: "1", price: "100")

    result = simulate

    assert_empty result.values,
                 "the basis is cash the moment a cash row exists, and no deposit means nothing to match"
  end

  test "result carries the benchmark instrument identity for the serializer" do
    result = simulate

    assert_equal @spy.id, result.instrument_id
    assert_equal "SPY", result.symbol
  end
end
