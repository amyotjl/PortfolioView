require "test_helper"

# Portfolio OHLC bounds, forward-fill, inception-anchored drawdown, and
# external flows (docs/PLAN.md § Core domain logic / § Verification).
class Portfolios::ValuationTest < ActiveSupport::TestCase
  include DomainTestHelper

  # A clean trading week: Mon 2026-07-06 .. Fri 2026-07-10.
  MON = Date.new(2026, 7, 6)
  TUE = Date.new(2026, 7, 7)
  WED = Date.new(2026, 7, 8)
  THU = Date.new(2026, 7, 9)
  FRI = Date.new(2026, 7, 10)

  setup do
    @portfolio = create_portfolio
    create_trading_days(MON, FRI)
  end

  def valuation(from:, to:, portfolio: @portfolio, **opts)
    Portfolios::Valuation.call(portfolio: portfolio, from: from, to: to, **opts)
  end

  test "portfolio OHLC is the share-weighted sum of component OHLC" do
    a = create_instrument(symbol: "AAA")
    b = create_instrument(symbol: "BBB")
    seed_prices(a, { MON => [ "10", "12", "9", "11" ] })
    seed_prices(b, { MON => [ "20", "22", "19", "21" ] })
    buy!(@portfolio, a, on: MON, shares: "2", price: "10")
    buy!(@portfolio, b, on: MON, shares: "3", price: "20")

    candle = valuation(from: MON, to: MON).candles.sole

    assert_equal bd("80"), candle.open   # 2x10 + 3x20
    assert_equal bd("90"), candle.high   # 2x12 + 3x22 — an upper BOUND
    assert_equal bd("75"), candle.low    # 2x9  + 3x19 — a lower BOUND
    assert_equal bd("85"), candle.close  # 2x11 + 3x21
  end

  test "meta.approximation is component_extrema on every response, including empty" do
    assert_equal "component_extrema", valuation(from: MON, to: FRI).meta[:approximation]

    aapl = create_instrument(symbol: "AAPL")
    seed_prices(aapl, { MON => "100" })
    buy!(@portfolio, aapl, on: MON, shares: "1", price: "100")
    assert_equal "component_extrema", valuation(from: MON, to: MON).meta[:approximation]
  end

  test "PLAN.md fixture: AAPL 4:1 pre-split buy values ~\$5,360 at the post-split close" do
    ex_date = Date.new(2020, 8, 31)
    create_trading_days(Date.new(2020, 8, 24), Date.new(2020, 9, 4))
    aapl = create_instrument(symbol: "AAPL")
    seed_prices(aapl, { Date.new(2020, 8, 27) => "500", Date.new(2020, 8, 28) => "499", ex_date => "134" })
    split!(aapl, on: ex_date, ratio: "4")
    buy!(@portfolio, aapl, on: Date.new(2020, 8, 27), shares: "10", price: "400")

    candles = valuation(from: Date.new(2020, 8, 27), to: ex_date).candles

    assert_equal bd("5000"), candles.first.close, "10 shares x \$500 pre-split"
    assert_equal bd("5360"), candles.last.close, "40 post-split shares x \$134"
  end

  test "a missing instrument-day forward-fills the last close into all four legs and is flagged" do
    a = create_instrument(symbol: "AAA")
    b = create_instrument(symbol: "BBB")
    seed_prices(a, { MON => [ "10", "12", "9", "11" ], TUE => [ "11", "13", "10", "12" ] })
    seed_prices(b, { MON => "20" }) # no TUE row
    buy!(@portfolio, a, on: MON, shares: "1", price: "10")
    buy!(@portfolio, b, on: MON, shares: "2", price: "20")

    result = valuation(from: MON, to: TUE)
    tuesday = result.candles.last

    # A's real OHLC plus B's flat 2 x 20 fill on every leg.
    assert_equal bd("51"), tuesday.open
    assert_equal bd("53"), tuesday.high
    assert_equal bd("50"), tuesday.low
    assert_equal bd("52"), tuesday.close
    assert_equal [ TUE ], result.meta[:filled_dates]
    assert_not result.meta[:partial]
  end

  test "a held instrument-day with no obtainable price sets meta.partial" do
    a = create_instrument(symbol: "AAA")
    buy!(@portfolio, a, on: MON, shares: "1", price: "10") # no prices seeded at all

    result = valuation(from: MON, to: MON)

    assert result.meta[:partial]
    assert_equal bd("0"), result.candles.sole.close
  end

  test "PLAN.md fixture: drawdown measures from the all-time peak even when the window starts after it" do
    aapl = create_instrument(symbol: "AAPL")
    seed_prices(aapl, { MON => "100", TUE => "150", WED => "120", THU => "130" })
    buy!(@portfolio, aapl, on: MON, shares: "1", price: "100")

    result = valuation(from: WED, to: THU)

    assert_equal [ WED, THU ], result.drawdown.map(&:date)
    assert_equal bd("-0.2"), result.drawdown.first.value, "(120-150)/150 against the TUE all-time peak"
    assert_equal bd("-0.13333333"), result.drawdown.last.value
    result.drawdown.each { |point| assert_instance_of BigDecimal, point.value }
  end

  test "drawdown is zero at and on the way up to new peaks" do
    aapl = create_instrument(symbol: "AAPL")
    seed_prices(aapl, { MON => "100", TUE => "150" })
    buy!(@portfolio, aapl, on: MON, shares: "1", price: "100")

    result = valuation(from: MON, to: TUE)

    assert_equal [ bd("0"), bd("0") ], result.drawdown.map(&:value)
  end

  test "flows: buys include fees, sells are net of fees" do
    aapl = create_instrument(symbol: "AAPL")
    seed_prices(aapl, { MON => "100", TUE => "120" })
    buy!(@portfolio, aapl, on: MON, shares: "10", price: "100", fees: "5")
    sell!(@portfolio, aapl, on: TUE, shares: "5", price: "120", fees: "3")

    flows = valuation(from: MON, to: TUE).flows

    assert_equal [ MON, TUE ], flows.map(&:date)
    assert_equal bd("1005"), flows.first.net,  "10 x 100 + 5 fees flows in"
    assert_equal bd("-597"), flows.last.net,   "5 x 120 - 3 fees flows out"
    assert_equal "AAPL", flows.first.items.sole.symbol
    flows.each { |flow| assert_instance_of BigDecimal, flow.net }
  end

  test "PLAN.md fixture: dividend_reinvestment transactions are excluded from flows but counted in holdings" do
    aapl = create_instrument(symbol: "AAPL")
    seed_prices(aapl, { MON => "100", TUE => "100" })
    buy!(@portfolio, aapl, on: MON, shares: "10", price: "100")
    buy!(@portfolio, aapl, on: TUE, shares: "0.5", price: "100", kind: "dividend_reinvestment")

    result = valuation(from: MON, to: TUE)

    assert_equal [ MON ], result.flows.map(&:date), "the DRIP is not an external flow"
    assert_equal bd("1050"), result.candles.last.close, "but the DRIP shares ARE part of the position"
  end

  test "a weekend transaction's flow lands on the next trading day" do
    aapl = create_instrument(symbol: "AAPL")
    seed_prices(aapl, { FRI => "100", Date.new(2026, 7, 13) => "100" })
    create_trading_days(Date.new(2026, 7, 13), Date.new(2026, 7, 13))
    buy!(@portfolio, aapl, on: Date.new(2026, 7, 11), shares: "1", price: "100") # Saturday

    flows = valuation(from: FRI, to: Date.new(2026, 7, 13)).flows

    assert_equal [ Date.new(2026, 7, 13) ], flows.map(&:date)
  end

  test "candles start at inception, not at the window start" do
    aapl = create_instrument(symbol: "AAPL")
    seed_prices(aapl, { WED => "100", THU => "110" })
    buy!(@portfolio, aapl, on: WED, shares: "1", price: "100")

    result = valuation(from: MON, to: THU)

    assert_equal [ WED, THU ], result.candles.map(&:date), "no candles before the first transaction"
  end

  test "injected transactions replace the stored ones (the benchmark-simulation seam)" do
    aapl = create_instrument(symbol: "AAPL")
    seed_prices(aapl, { MON => "100" })
    buy!(@portfolio, aapl, on: MON, shares: "999", price: "1") # must be ignored

    synthetic = Data.define(:instrument_id, :side, :kind, :shares, :price, :fees, :executed_on)
    injected = [ synthetic.new(instrument_id: aapl.id, side: "buy", kind: "normal",
                               shares: bd("2"), price: bd("100"), fees: bd("0"), executed_on: MON) ]

    result = valuation(from: MON, to: MON, transactions: injected)

    assert_equal bd("200"), result.candles.sole.close
    assert_equal bd("200"), result.flows.sole.net
  end

  test "empty portfolio returns empty series with full meta" do
    result = valuation(from: MON, to: FRI)

    assert_empty result.candles
    assert_empty result.drawdown
    assert_empty result.flows
    assert_equal "component_extrema", result.meta[:approximation]
    assert_empty result.meta[:filled_dates]
    assert_not result.meta[:partial]
  end

  test "all candle legs are BigDecimal — never Float" do
    aapl = create_instrument(symbol: "AAPL")
    seed_prices(aapl, { MON => [ "10.123456", "12.5", "9.25", "11.75" ] })
    buy!(@portfolio, aapl, on: MON, shares: "0.33333333", price: "10")

    candle = valuation(from: MON, to: MON).candles.sole

    [ candle.open, candle.high, candle.low, candle.close ].each do |leg|
      assert_instance_of BigDecimal, leg
    end
    assert_equal bd("0.33333333") * bd("11.75"), candle.close
  end

  test "result collections are frozen" do
    result = valuation(from: MON, to: FRI)

    assert_predicate result, :frozen?
    assert_predicate result.candles, :frozen?
    assert_predicate result.meta, :frozen?
  end
end
