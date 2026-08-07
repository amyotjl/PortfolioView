require "test_helper"

# issue #80, the cross-endpoint half: the promise that a portfolio WITHOUT cash
# rows is byte-identical to what it was before the feature, and the invariants
# that keep /summary and /candles from contradicting each other once cash exists.
class CashBasisContractTest < ActionDispatch::IntegrationTest
  include DomainTestHelper

  MON = Date.new(2026, 7, 6)
  TUE = Date.new(2026, 7, 7)
  WED = Date.new(2026, 7, 8)
  THU = Date.new(2026, 7, 9)
  FRI = Date.new(2026, 7, 10)

  setup do
    @user = users(:one)
    sign_in_as @user
    @spy = create_trading_days(MON, FRI, closes: { MON => 100, TUE => 110, WED => 105, THU => 115, FRI => 125 })
    @benchmark = ::Benchmark.create!(instrument: @spy, name: "S&P 500 (SPY)")
    @portfolio = create_portfolio(benchmark: @benchmark)
    @aapl = create_instrument(symbol: "AAPL")
    seed_prices(@aapl, { MON => [ "100", "105", "95", "100" ], TUE => 150, WED => 120, THU => 140, FRI => 130 })
  end

  def candles(portfolio: @portfolio, **params)
    get candles_api_v1_portfolio_path(portfolio, params)
    assert_response :ok
    JSON.parse(response.body)
  end

  def summary(portfolio: @portfolio)
    get summary_api_v1_portfolio_path(portfolio)
    assert_response :ok
    JSON.parse(response.body).fetch("summary")
  end

  # ---------------------------------------------------------------------------
  # 1. THE OWNER'S PROMISE, MECHANIZED. A trades-only portfolio's payloads are
  #    pinned in full, by hand, from the PLAN.md formulas — not copied from a
  #    run. Every figure below is the pre-#80 figure.
  #
  #    10 AAPL @ $100 + $5 fee on MON. Holdings value = 10 x that day's leg.
  #    Flow = 10x100 + 5 = 1005 on MON. Drawdown peaks TUE at 1500.
  # ---------------------------------------------------------------------------
  test "a portfolio with no cash rows is byte-identical on /candles" do
    buy!(@portfolio, @aapl, on: MON, shares: "10", price: "100", fees: "5")

    expected = {
      "candles" => [
        { "t" => "2026-07-06", "o" => "1000.0", "h" => "1050.0", "l" => "950.0", "c" => "1000.0" },
        { "t" => "2026-07-07", "o" => "1500.0", "h" => "1500.0", "l" => "1500.0", "c" => "1500.0" },
        { "t" => "2026-07-08", "o" => "1200.0", "h" => "1200.0", "l" => "1200.0", "c" => "1200.0" },
        { "t" => "2026-07-09", "o" => "1400.0", "h" => "1400.0", "l" => "1400.0", "c" => "1400.0" },
        { "t" => "2026-07-10", "o" => "1300.0", "h" => "1300.0", "l" => "1300.0", "c" => "1300.0" }
      ],
      "benchmark" => nil,
      "flows" => [
        { "t" => "2026-07-06", "net" => "1005.0",
          "items" => [ { "ticker" => "AAPL", "kind" => "buy", "amount" => "1005.0" } ] }
      ],
      "drawdown" => [
        { "t" => "2026-07-06", "v" => "0.0" },          # first day IS the peak
        { "t" => "2026-07-07", "v" => "0.0" },          # new peak 1500
        { "t" => "2026-07-08", "v" => "-0.2" },         # (1200-1500)/1500
        { "t" => "2026-07-09", "v" => "-0.06666667" },  # (1400-1500)/1500
        { "t" => "2026-07-10", "v" => "-0.13333333" }   # (1300-1500)/1500
      ],
      # The new keys, in their UNTRACKED form: null, never [] and never "trades"-
      # plus-a-zero-series.
      "cash" => nil,
      "meta" => {
        "partial" => false, "filled_dates" => [], "benchmark_clamped" => false,
        "approximation" => "component_extrema",
        "flow_basis" => "trades", "cash_negative" => false, "cash_negative_since" => nil
      }
    }

    assert_equal expected, candles(from: MON.iso8601, to: FRI.iso8601)
  end

  test "a portfolio with no cash rows is byte-identical on /summary" do
    buy!(@portfolio, @aapl, on: MON, shares: "10", price: "100", fees: "5")

    expected = {
      "current_value" => "1300.0",       # 10 x FRI 130 — holdings only
      "holdings_value" => "1300.0",      # ...and identical to it
      "cash_balance" => nil,             # NOT "0.00": this portfolio has no cash account
      "net_deposits" => "1005.0",        # the trade basis, fees included
      "deposit_basis" => "trades",
      "total_return" => "295.0",         # 1300 - 1005
      "total_return_pct" => "0.293532",  # 295/1005
      "benchmark_return_pct" => "0.25",  # $1005 buys 10.05 SPY @ 100 -> x125 = 1256.25
      "vs_benchmark_edge_pct" => "0.043532",
      "max_drawdown_pct" => "-0.2",
      "cash_negative" => false,
      "cash_negative_since" => nil,
      "as_of" => "2026-07-10"
    }

    assert_equal expected, summary
  end

  # ---------------------------------------------------------------------------
  # 7. The live bug: a deposit predating the first trade.
  # ---------------------------------------------------------------------------
  test "a deposit predating the first trade is counted, not silently dropped from net_deposits" do
    cash!(@portfolio, kind: "deposit", amount: "10000.00", on: MON)
    buy!(@portfolio, @aapl, on: WED, shares: "10", price: "100")

    result = summary

    assert_equal "10000.0", result["net_deposits"], "the MON deposit is the contribution"
    assert_equal "1300.0", result["holdings_value"], "10 AAPL x FRI 130"
    assert_equal "9000.0", result["cash_balance"], "10,000 in, 1,000 spent"
    assert_equal "10300.0", result["current_value"], "holdings + cash"
    assert_equal "300.0", result["total_return"], "and the return is the real one"
    assert_equal "cash", result["deposit_basis"]

    # The window default follows the same inception, so the chart starts at the
    # deposit rather than at the first trade.
    assert_equal "2026-07-06", candles.fetch("candles").first["t"]
  end

  # ---------------------------------------------------------------------------
  # 9. Sum(flows[].net) == summary.net_deposits, in BOTH bases. Summary literally
  #    sums that array, so a mixed or windowed array silently corrupts the tile.
  # ---------------------------------------------------------------------------
  test "the sum of flows equals net_deposits on the trade basis" do
    buy!(@portfolio, @aapl, on: MON, shares: "10", price: "100", fees: "5")
    buy!(@portfolio, @aapl, on: WED, shares: "5", price: "120")
    sell!(@portfolio, @aapl, on: THU, shares: "2", price: "140", fees: "1")

    flows = candles.fetch("flows")
    total = flows.sum(BigDecimal(0)) { |flow| BigDecimal(flow["net"]) }

    assert_equal "trades", candles.dig("meta", "flow_basis")
    assert_equal BigDecimal(summary.fetch("net_deposits")), total
  end

  test "the sum of flows equals net_deposits on the cash basis, and carries no trade items" do
    cash!(@portfolio, kind: "deposit", amount: "10000.00", on: MON)
    cash!(@portfolio, kind: "withdrawal", amount: "-1500.00", on: THU)
    cash!(@portfolio, kind: "interest", amount: "2.50", on: THU)
    buy!(@portfolio, @aapl, on: TUE, shares: "10", price: "150", fees: "5")

    payload = candles
    flows = payload.fetch("flows")
    total = flows.sum(BigDecimal(0)) { |flow| BigDecimal(flow["net"]) }

    assert_equal "cash", payload.dig("meta", "flow_basis")
    assert_equal BigDecimal("8500"), total, "10,000 deposited - 1,500 withdrawn; interest is not a contribution"
    assert_equal BigDecimal(summary.fetch("net_deposits")), total

    kinds = flows.flat_map { |flow| flow.fetch("items").map { |item| item["kind"] } }
    assert_equal %w[deposit withdrawal], kinds, "no buy/sell bars, and no interest bar"
    flows.each do |flow|
      flow.fetch("items").each { |item| assert_nil item["ticker"], "a cash movement has no ticker" }
    end
  end

  # ---------------------------------------------------------------------------
  # Cross-endpoint coherence.
  # ---------------------------------------------------------------------------
  test "deposit_basis cash <=> candles.cash non-null <=> cash_balance non-null, and the series ends at the tile" do
    cash!(@portfolio, kind: "deposit", amount: "10000.00", on: MON)
    buy!(@portfolio, @aapl, on: TUE, shares: "10", price: "150")

    result = summary
    payload = candles

    assert_equal "cash", result["deposit_basis"]
    assert_not_nil result["cash_balance"]
    assert_not_nil payload.fetch("cash")
    assert_equal payload.fetch("candles").map { |c| c["t"] }, payload.fetch("cash").map { |p| p["t"] },
                 "the cash series is index-aligned with the candles"
    assert_equal result["cash_balance"], payload.fetch("cash").last["v"],
                 "the tile IS the last point of the series"
    assert_equal result["holdings_value"], payload.fetch("candles").last["c"]
    assert_equal BigDecimal(result["current_value"]),
                 BigDecimal(result["holdings_value"]) + BigDecimal(result["cash_balance"])
  end

  # The state a single `?? 0` in the chain erases: tracked AND exactly flat. It
  # must be a money string, and it must NOT look like the untracked case.
  test "a tracked portfolio that is exactly flat reports a zero balance, not null" do
    cash!(@portfolio, kind: "deposit", amount: "1000.00", on: MON)
    buy!(@portfolio, @aapl, on: MON, shares: "10", price: "100")

    result = summary

    assert_equal "0.0", result["cash_balance"], "flat is a figure, not an absence"
    assert_equal "cash", result["deposit_basis"]
    assert_equal "1000.0", result["net_deposits"]
    assert_equal "1300.0", result["current_value"], "all of it is invested"
  end

  test "a cash-only portfolio charts its cash instead of the empty state" do
    cash!(@portfolio, kind: "deposit", amount: "10000.00", on: MON)

    payload = candles
    result = summary

    assert_equal 5, payload.fetch("candles").size, "a real portfolio, not 'nothing to chart yet'"
    assert_equal [ "0.0" ] * 5, payload.fetch("candles").map { |c| c["c"] }
    assert_equal [ "10000.0" ] * 5, payload.fetch("cash").map { |p| p["v"] }
    assert_equal "10000.0", result["current_value"]
    assert_equal "0.0", result["holdings_value"]
    assert_equal "0.0", result["total_return"]
  end

  # 16. Cash the price cache cannot place yet.
  test "cash beyond the price cache flags meta.partial and is never cached" do
    buy!(@portfolio, @aapl, on: MON, shares: "1", price: "100")
    beyond = Date.new(2026, 7, 13) # no SPY row
    cash!(@portfolio, kind: "deposit", amount: "5000.00", on: beyond)

    payload = candles(from: MON.iso8601, to: beyond.iso8601)

    assert_equal true, payload.dig("meta", "partial"),
                 "unplaceable cash must surface as partial, never be silently dropped"
  end

  # 2/3 at the HTTP level: the benchmark denominator follows the basis.
  test "the benchmark is deposit-matched on the cash basis" do
    # $10,000 deposited MON (SPY 100 -> 100 shares), invested WED. SPY ends 125,
    # so the shadow ETF is 100 x 125 = 12,500 -> +25% on the 10,000 deposited.
    cash!(@portfolio, kind: "deposit", amount: "10000.00", on: MON)
    buy!(@portfolio, @aapl, on: WED, shares: "10", price: "120")

    result = summary

    assert_equal "10000.0", result["net_deposits"]
    assert_equal "0.25", result["benchmark_return_pct"], "matched on the deposit, on its own date"
  end
end
