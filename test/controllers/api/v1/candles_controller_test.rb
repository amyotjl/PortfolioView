require "test_helper"

# backlog #031: GET /api/v1/portfolios/:id/candles — the frozen candles shape
# (docs/PLAN.md § API contract), served through the #033 key-rotation cache.
module Api
  module V1
    class CandlesControllerTest < ActionDispatch::IntegrationTest
      include DomainTestHelper

      MON = Date.new(2026, 7, 6)
      TUE = Date.new(2026, 7, 7)
      WED = Date.new(2026, 7, 8)
      THU = Date.new(2026, 7, 9)
      FRI = Date.new(2026, 7, 10)

      META_KEYS = %w[partial filled_dates benchmark_clamped approximation].freeze

      setup do
        @user = users(:one)
        sign_in_as @user
        @spy = create_trading_days(MON, FRI, closes: {
          MON => 100, TUE => 110, WED => 105, THU => 115, FRI => 125
        })
        @benchmark = ::Benchmark.create!(instrument: @spy, name: "S&P 500 (SPY)")
        @portfolio = create_portfolio(benchmark: @benchmark)
        @aapl = create_instrument(symbol: "AAPL")
        seed_prices(@aapl, { MON => [ "100", "105", "95", "100" ], TUE => 150, WED => 120, THU => 140, FRI => 130 })
        buy!(@portfolio, @aapl, on: MON, shares: "10", price: "100", fees: "5")
      end

      def get_candles(portfolio: @portfolio, **params)
        get candles_api_v1_portfolio_path(portfolio, params)
        JSON.parse(response.body)
      end

      # --- Auth + scoping ---

      test "requires an authenticated session" do
        sign_out
        get candles_api_v1_portfolio_path(@portfolio)
        assert_response :unauthorized
      end

      test "another user's portfolio is the uniform 404 envelope" do
        other = Portfolio.create!(user: users(:two), name: "Not Yours")
        get candles_api_v1_portfolio_path(other)
        assert_response :not_found
        assert_equal "not_found", JSON.parse(response.body).dig("error", "code")
      end

      # --- Frozen shape ---

      test "returns candles [{t,o,h,l,c}] from Valuation for the requested range" do
        body = get_candles(from: MON.iso8601, to: MON.iso8601)
        assert_response :ok

        candle = body.fetch("candles").sole
        assert_equal %w[t o h l c].sort, candle.keys.sort
        assert_equal "2026-07-06", candle["t"]
        assert_equal "1000.0", candle["o"] # 10 x 100
        assert_equal "1050.0", candle["h"] # 10 x 105 (upper BOUND)
        assert_equal "950.0",  candle["l"] # 10 x 95  (lower BOUND)
        assert_equal "1000.0", candle["c"] # 10 x 100
      end

      test "benchmark=true adds a close-value LINE {symbol, values:[{t,v}]}, never candles" do
        body = get_candles(from: MON.iso8601, to: FRI.iso8601, benchmark: true)
        assert_response :ok

        benchmark = body.fetch("benchmark")
        assert_equal %w[symbol values].sort, benchmark.keys.sort
        assert_equal "SPY", benchmark["symbol"]

        point = benchmark["values"].first
        assert_equal %w[t v].sort, point.keys.sort, "benchmark is a LINE, not candles (no o/h/l/c)"
        # $1005 (cost 1000 + $5 fee) buys 10.05 SPY @ 100 -> 10.05 x 125 = 1256.25 on FRI
        assert_equal "1256.25", benchmark["values"].last["v"]
      end

      test "benchmark is null when not requested" do
        body = get_candles(from: MON.iso8601, to: FRI.iso8601)
        assert_nil body.fetch("benchmark")
      end

      test "flows carry {t, net, items:[{ticker,kind,amount}]} and exclude DRIP" do
        # A dividend_reinvestment on TUE must NOT appear as external cash.
        buy!(@portfolio, @aapl, on: TUE, shares: "1", price: "150", kind: "dividend_reinvestment")

        body = get_candles(from: MON.iso8601, to: FRI.iso8601)
        flows = body.fetch("flows")

        assert_equal [ "2026-07-06" ], flows.map { |f| f["t"] }, "DRIP contributes no external flow"
        flow = flows.sole
        assert_equal "1005.0", flow["net"] # 10 x 100 + $5 fee
        item = flow["items"].sole
        assert_equal %w[ticker kind amount].sort, item.keys.sort
        assert_equal "AAPL", item["ticker"]
        assert_equal "buy", item["kind"]
        assert_equal "1005.0", item["amount"]
      end

      test "drawdown is measured from the inception all-time peak regardless of the window" do
        # Value peaks at 1500 on TUE (before the window), dips to 1200 on WED.
        body = get_candles(from: WED.iso8601, to: FRI.iso8601)
        drawdown = body.fetch("drawdown")

        assert_equal [ "2026-07-08", "2026-07-09", "2026-07-10" ], drawdown.map { |d| d["t"] },
          "only the window's points are emitted"
        assert_equal %w[t v].sort, drawdown.first.keys.sort
        # WED: (1200 - 1500)/1500 = -0.2 — from the pre-window peak, NOT the window's first value
        assert_equal "-0.2", drawdown.first["v"]
      end

      test "meta carries exactly partial, filled_dates, benchmark_clamped, approximation" do
        body = get_candles(from: MON.iso8601, to: FRI.iso8601, benchmark: true)
        meta = body.fetch("meta")

        assert_equal META_KEYS.sort, meta.keys.sort
        assert_equal false, meta["partial"]
        assert_equal [], meta["filled_dates"]
        assert_equal false, meta["benchmark_clamped"]
        assert_equal "component_extrema", meta["approximation"]
      end

      test "an empty portfolio returns a well-formed empty payload" do
        empty = create_portfolio(name: "Empty", benchmark: @benchmark)
        body = get_candles(portfolio: empty, benchmark: true)

        assert_response :ok
        assert_equal [], body["candles"]
        assert_equal [], body["flows"]
        assert_equal [], body["drawdown"]
        assert_equal false, body.dig("meta", "partial")
      end

      # --- Validation ---

      test "a malformed date answers 422 mapped onto the field" do
        get_candles(from: "not-a-date", to: FRI.iso8601)
        assert_response :unprocessable_entity
        details = JSON.parse(response.body).dig("error", "details")
        assert details.key?("from")
      end

      # --- Caching (#033 integration) ---

      test "a cache hit serves the second identical request without recomputing the valuation" do
        params = { from: MON.iso8601, to: FRI.iso8601, benchmark: true }

        miss_queries = count_queries { get_candles(**params) }
        assert_response :ok
        hit_queries = count_queries { get_candles(**params) }
        assert_response :ok

        assert_operator hit_queries, :<, miss_queries,
          "a cache hit must skip the valuation/simulation recompute"
      end

      test "a transaction mutation bumps series_version and rotates the key to fresh data" do
        params = { from: MON.iso8601, to: FRI.iso8601 }

        first = get_candles(**params).fetch("candles")
        buy!(@portfolio, @aapl, on: MON, shares: "10", price: "100") # bumps series_version
        second = get_candles(**params).fetch("candles")

        assert_not_equal first, second, "the new transaction must not be served from the stale cache"
        # FRI close doubled: now 20 shares x 130 = 2600
        assert_equal "2600.0", second.last["c"]
      end
    end
  end
end
