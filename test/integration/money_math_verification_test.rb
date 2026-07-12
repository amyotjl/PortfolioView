require "test_helper"

# Independent end-to-end money-math verification (backlog #024, docs/PLAN.md
# §§ Core domain logic / Recurring materializer / Verification).
#
# This suite is deliberately INDEPENDENT of the implementer's per-service tests:
# every expected value below is derived BY HAND from the PLAN.md formulas
# (arithmetic shown in comments), NOT copied from the service test files. It
# drives ONE scenario spanning the whole money-math stack — a multi-instrument
# portfolio crossing the real AAPL 4:1 split, a recurring rule that materializes
# a trade, a DRIP buy, fees, and a benchmark comparison — and pins exact
# BigDecimal values at several dates through Portfolios::Valuation and
# Benchmarks::Simulation.
#
# --------------------------------------------------------------------------
# THE SCENARIO (all prices are unadjusted; the AAPL 4:1 ex-date is real:
# Monday 2020-08-31, and a split applies at the START of its ex-date).
#
# Trading calendar (SPY has a row) = 5 days:
#   Thu 2020-08-27 (D1), Fri 08-28 (D2), Mon 08-31 (EX, AAPL 4:1),
#   Tue 09-01 (D4), Wed 09-02 (D5).
#
# Component unadjusted prices:
#           AAPL (o/h/l/c)              MSFT (o/h/l/c)      SPY close
#   08-27   498 / 505 / 495 / 500       198/203/197/200     100
#   08-28   flat 510                    flat 200            100
#   08-31   flat 130   (post-split)     flat 210            120
#   09-01   flat 134                    flat 220            120
#   09-02   flat 120.6                  flat 198            108
#
# Transactions:
#   T1  08-27  BUY  10 AAPL @ $400, fees $10           (kind normal)
#   T2  08-27  BUY   5 MSFT @ $200, fees  $0           (kind normal)
#   DR  08-28  BUY 0.4 AAPL @ $510                      (kind dividend_reinvestment)
#   R   08-28  recurring rule materializes BUY of $600 MSFT @ that day's $200
#              close = 3 MSFT shares                    (kind normal)
#
# --------------------------------------------------------------------------
# CSF / share counts (PLAN.md: CSF(i,t,D) = product of ratios with t < ex_date <= D;
# split applies at the START of the ex-date, so trades ON/AFTER it are post-split):
#
#   AAPL pre-split (through 08-28): T1 10  +  DR 0.4          = 10.4
#   AAPL on/after EX 08-31:        10.4 x 4 (the 4:1 split)  = 41.6
#   MSFT (no split): T2 5  +  R 3                            = 8   (from 08-28 on)
#
# --------------------------------------------------------------------------
# PORTFOLIO VALUATION  (portfolio leg = sum of shares(i,D) x component leg):
#
#   08-27  open  = 10x498 + 5x198 = 4980 + 990 = 5970
#          high  = 10x505 + 5x203 = 5050 + 1015 = 6065   (an upper BOUND)
#          low   = 10x495 + 5x197 = 4950 + 985 = 5935    (a lower BOUND)
#          close = 10x500 + 5x200 = 5000 + 1000 = 6000
#   08-28  close = 10.4x510 + 8x200 = 5304 + 1600 = 6904   (DRIP + recurring in position)
#   08-31  close = 41.6x130 + 8x210 = 5408 + 1680 = 7088   (4:1 split applied)
#   09-01  close = 41.6x134 + 8x220 = 5574.4 + 1760 = 7334.4   (all-time peak)
#   09-02  close = 41.6x120.6 + 8x198 = 5016.96 + 1584 = 6600.96
#
# FLOWS (external cash; DRIP excluded; buy = shares x price + fees):
#   08-27  net = (10x400 + 10) + (5x200 + 0) = 4010 + 1000 = 5010
#   08-28  net = 3x200 + 0 = 600                (the DRIP contributes NO flow)
#
# DRAWDOWN (against the ALL-TIME peak, inception-to-date):
#   peak = 7334.4 (09-01). On 09-02: (6600.96 - 7334.4)/7334.4 = -733.44/7334.4 = -0.1 exactly.
#
# --------------------------------------------------------------------------
# BENCHMARK SIMULATION (each non-DRIP trade -> same-dollar SPY buy at the first
# SPY close on/after executed_on; buys convert cost + fees):
#
#   T1 08-27: $4010 / $100 = 40.1 SPY shares
#   T2 08-27: $1000 / $100 = 10   SPY shares
#   R  08-28: $600  / $100 =  6   SPY shares      (DRIP DR contributes nothing)
#
#   value line = cumulative SPY shares x SPY close:
#   08-27  (40.1 + 10) x 100 = 50.1 x 100 = 5010    (== the 08-27 flow: cash-flow matched)
#   08-28  56.1 x 100 = 5610
#   08-31  56.1 x 120 = 6732
#   09-01  56.1 x 120 = 6732
#   09-02  56.1 x 108 = 6058.8
# --------------------------------------------------------------------------
class MoneyMathVerificationTest < ActiveSupport::TestCase
  include DomainTestHelper

  D1 = Date.new(2020, 8, 27) # Thu
  D2 = Date.new(2020, 8, 28) # Fri
  EX = Date.new(2020, 8, 31) # Mon — AAPL 4:1 ex-date
  D4 = Date.new(2020, 9, 1)  # Tue
  D5 = Date.new(2020, 9, 2)  # Wed

  setup do
    # SPY is both the trading calendar and the benchmark ETF.
    @spy = create_trading_days(D1, D5, closes: {
      D1 => "100", D2 => "100", EX => "120", D4 => "120", D5 => "108"
    })
    @benchmark = ::Benchmark.create!(name: "S&P 500 (verification)", instrument: @spy)
    @portfolio = create_portfolio(benchmark: @benchmark)

    @aapl = create_instrument(symbol: "AAPL")
    @msft = create_instrument(symbol: "MSFT")

    seed_prices(@aapl, {
      D1 => [ "498", "505", "495", "500" ],
      D2 => "510",
      EX => "130",   # unadjusted post-split close
      D4 => "134",
      D5 => "120.6"
    })
    seed_prices(@msft, {
      D1 => [ "198", "203", "197", "200" ],
      D2 => "200",
      EX => "210",
      D4 => "220",
      D5 => "198"
    })
    split!(@aapl, on: EX, ratio: "4")

    # T1, T2 — the two founding buys (T1 carries a $10 fee).
    buy!(@portfolio, @aapl, on: D1, shares: "10", price: "400", fees: "10")
    buy!(@portfolio, @msft, on: D1, shares: "5",  price: "200", fees: "0")

    # DR — a dividend-reinvestment AAPL buy: adds shares to the position but is
    # NOT an external flow and must NOT be matched by the benchmark.
    buy!(@portfolio, @aapl, on: D2, shares: "0.4", price: "510", kind: "dividend_reinvestment")

    # R — a recurring $600/month MSFT rule; materialize its single in-window slot
    # (08-28). Created with a far-future next_run_on so the on-create forward
    # clamp leaves it alone, then rewound to the historical slot (the pattern the
    # materializer itself relies on for catch-up).
    @rule = RecurringTransaction.create!(
      portfolio: @portfolio, instrument: @msft, side: "buy",
      amount_type: "dollars", dollar_amount: "600.00",
      frequency: "monthly", anchor_on: D2, next_run_on: Date.new(2099, 1, 1)
    )
    @rule.update_columns(next_run_on: D2)
    materialize = Recurring::Materializer.call(rule: @rule.reload, today: D5)
    assert_equal 1, materialize.filled, "exactly the 08-28 slot materializes in this window"
  end

  def valuation(from:, to:)
    Portfolios::Valuation.call(portfolio: @portfolio, from: from, to: to)
  end

  def simulation(from:, to:)
    Benchmarks::Simulation.call(portfolio: @portfolio, from: from, to: to)
  end

  # ----- recurring materialization landed exactly one clean trade -----------

  test "the recurring rule materialized one $600 MSFT buy at the 08-28 close" do
    trade = @rule.transactions.sole

    assert_equal D2, trade.scheduled_for
    assert_equal D2, trade.executed_on, "execution date = first trading day >= slot"
    assert_equal bd("3"), trade.shares, "600 / 200 close = 3 shares"
    assert_equal bd("200"), trade.price
    assert_equal "normal", trade.kind
    assert_instance_of BigDecimal, trade.shares
  end

  # ----- portfolio valuation: OHLC bounds, split, DRIP, recurring ------------

  test "08-27 portfolio OHLC is the share-weighted sum of component OHLC (H/L are bounds)" do
    candle = valuation(from: D1, to: D1).candles.sole

    assert_equal bd("5970"), candle.open   # 10x498 + 5x198
    assert_equal bd("6065"), candle.high   # 10x505 + 5x203 (upper bound)
    assert_equal bd("5935"), candle.low    # 10x495 + 5x197 (lower bound)
    assert_equal bd("6000"), candle.close  # 10x500 + 5x200
  end

  test "closes track the full timeline: DRIP + recurring shares, then the 4:1 split, then a dip" do
    candles = valuation(from: D1, to: D5).candles.index_by(&:date)

    assert_equal [ D1, D2, EX, D4, D5 ], valuation(from: D1, to: D5).candles.map(&:date)
    assert_equal bd("6000"),    candles[D1].close  # 10x500 + 5x200
    assert_equal bd("6904"),    candles[D2].close  # 10.4x510 + 8x200 (DRIP + recurring)
    assert_equal bd("7088"),    candles[EX].close  # 41.6x130 + 8x210 (post-split)
    assert_equal bd("7334.4"),  candles[D4].close  # 41.6x134 + 8x220
    assert_equal bd("6600.96"), candles[D5].close  # 41.6x120.6 + 8x198
  end

  test "the 4:1 split multiplies the AAPL contribution but not MSFT's (isolated per instrument)" do
    # Cross-check the split boundary directly: AAPL close jumps by the split
    # factor absent any new AAPL trade between 08-28 and 08-31.
    #   AAPL contribution 08-28 = 10.4 x 510 = 5304
    #   AAPL contribution 08-31 = 41.6 x 130 = 5408  (== 10.4 x 4 x 130)
    v = valuation(from: D2, to: EX)
    d2, ex = v.candles.index_by(&:date).values_at(D2, EX)

    assert_equal bd("5304") + bd("1600"), d2.close
    assert_equal bd("5408") + bd("1680"), ex.close
    # MSFT contribution is unsplit: 8 shares throughout.
    assert_equal bd("1600"), bd("8") * bd("200")
    assert_equal bd("1680"), bd("8") * bd("210")
  end

  test "meta.approximation flags the H/L-are-bounds caveat on the response" do
    assert_equal "component_extrema", valuation(from: D1, to: D5).meta[:approximation]
  end

  # ----- flows: fees included, DRIP excluded --------------------------------

  test "flows include buy fees and exclude the DRIP" do
    flows = valuation(from: D1, to: D5).flows.index_by(&:date)

    assert_equal [ D1, D2 ], valuation(from: D1, to: D5).flows.map(&:date),
                 "only the two external-cash dates; the 08-28 DRIP is not a flow"
    assert_equal bd("5010"), flows[D1].net   # (10x400 + 10) + (5x200)
    assert_equal bd("600"),  flows[D2].net   # 3x200 recurring buy; DRIP contributes nothing
    assert_equal [ "AAPL", "MSFT" ], flows[D1].items.map(&:symbol).sort
    flows.each_value { |flow| assert_instance_of BigDecimal, flow.net }
  end

  # ----- drawdown from the ALL-TIME peak ------------------------------------

  test "drawdown is measured from the all-time peak even when the window starts after it" do
    # Peak is 09-01 (7334.4). Ask for a window that STARTS on 09-02, after the
    # peak: the drawdown must still measure against 7334.4, not a window-local peak.
    result = valuation(from: D5, to: D5)

    assert_equal [ D5 ], result.drawdown.map(&:date)
    # (6600.96 - 7334.4) / 7334.4 = -733.44 / 7334.4 = -0.1 exactly.
    assert_equal bd("-0.1"), result.drawdown.sole.value
    assert_instance_of BigDecimal, result.drawdown.sole.value
  end

  test "drawdown is zero while climbing to new peaks" do
    dd = valuation(from: D1, to: D4).drawdown.index_by(&:date)

    assert_equal bd("0"), dd[D1].value
    assert_equal bd("0"), dd[D2].value
    assert_equal bd("0"), dd[EX].value
    assert_equal bd("0"), dd[D4].value, "09-01 IS the peak, so no drawdown yet"
  end

  # ----- benchmark simulation: exact-dollar matching incl. fees, DRIP out ----

  test "benchmark converts each non-DRIP trade to same-dollar SPY incl. fees" do
    values = simulation(from: D1, to: D5).values.index_by(&:date)

    # 08-27: T1 $4010/100 = 40.1 sh, T2 $1000/100 = 10 sh -> (40.1+10) x 100 = 5010
    assert_equal bd("5010"), values[D1].value, "matches the 08-27 cash flow exactly (fill on the trade day)"
    # 08-28: + R $600/100 = 6 sh -> 56.1 x 100 = 5610 (DRIP added nothing)
    assert_equal bd("5610"), values[D2].value
    assert_equal bd("6732"), values[EX].value  # 56.1 x 120
    assert_equal bd("6732"), values[D4].value  # 56.1 x 120
    assert_equal bd("6058.8"), values[D5].value # 56.1 x 108
  end

  test "the DRIP is excluded from benchmark matching (no free shadow money)" do
    # If the 0.4-share AAPL DRIP had been matched, it would have bought SPY on
    # 08-28 and lifted every value from 08-28 on. Pin 08-28 to prove it did not:
    # 56.1 shares (T1+T2+R only), not more.
    assert_equal bd("5610"), simulation(from: D1, to: D5).values.find { |p| p.date == D2 }.value
  end

  test "benchmark output is price-return, unclamped, and all-BigDecimal" do
    result = simulation(from: D1, to: D5)

    assert_equal "price_return", result.meta[:return_basis]
    assert_not result.meta[:benchmark_clamped], "all buys — nothing over-withdrawn"
    assert_equal @spy.id, result.instrument_id
    assert_equal "SPY", result.symbol
    result.values.each { |point| assert_instance_of BigDecimal, point.value }
  end

  # ----- numeric discipline: Float genuinely cannot flow through ------------

  test "a Float share count cannot enter the money math (MoneyMath rejects it)" do
    synthetic = Data.define(:instrument_id, :side, :kind, :shares, :price, :fees, :executed_on)
    injected = [ synthetic.new(instrument_id: @aapl.id, side: "buy", kind: "normal",
                               shares: 10.0, price: bd("400"), fees: bd("0"), executed_on: D1) ]

    assert_raises TypeError do
      Portfolios::Valuation.call(portfolio: @portfolio, from: D1, to: D1, transactions: injected)
    end
  end
end
