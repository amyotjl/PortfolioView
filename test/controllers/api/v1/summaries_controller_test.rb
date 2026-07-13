require "test_helper"

# backlog #032: GET /api/v1/portfolios/:id/summary — lifetime stat tiles
# computed over full history (docs/PLAN.md § API contract).
module Api
  module V1
    class SummariesControllerTest < ActionDispatch::IntegrationTest
      include DomainTestHelper

      MON = Date.new(2026, 7, 6)
      TUE = Date.new(2026, 7, 7)
      WED = Date.new(2026, 7, 8)
      THU = Date.new(2026, 7, 9)
      FRI = Date.new(2026, 7, 10)

      SUMMARY_KEYS = %w[
        current_value net_deposits total_return total_return_pct
        benchmark_return_pct vs_benchmark_edge_pct max_drawdown_pct as_of
      ].freeze

      setup do
        @user = users(:one)
        sign_in_as @user
      end

      def get_summary(portfolio)
        get summary_api_v1_portfolio_path(portfolio)
        JSON.parse(response.body).fetch("summary")
      end

      # --- Auth + scoping ---

      test "requires an authenticated session" do
        portfolio = create_portfolio
        sign_out
        get summary_api_v1_portfolio_path(portfolio)
        assert_response :unauthorized
      end

      test "another user's portfolio is the uniform 404 envelope, no data leak" do
        other = Portfolio.create!(user: users(:two), name: "Not Yours")
        get summary_api_v1_portfolio_path(other)
        assert_response :not_found
        assert_equal "not_found", JSON.parse(response.body).dig("error", "code")
      end

      # --- Empty portfolio: well-formed zero payload ---

      test "an empty portfolio returns a well-formed zero payload, not an error" do
        summary = get_summary(create_portfolio)

        assert_response :ok
        assert_equal SUMMARY_KEYS.sort, summary.keys.sort
        assert_equal "0.0", summary["current_value"]
        assert_equal "0.0", summary["net_deposits"]
        assert_equal "0.0", summary["total_return"]
        assert_nil summary["total_return_pct"]
        assert_nil summary["benchmark_return_pct"]
        assert_nil summary["vs_benchmark_edge_pct"]
        assert_equal "0.0", summary["max_drawdown_pct"]
        assert_nil summary["as_of"]
      end

      # --- Full lifetime math incl. benchmark edge + all-time-peak drawdown ---

      test "computes lifetime tiles, benchmark edge, and drawdown from the all-time peak" do
        spy = create_trading_days(MON, FRI, closes: {
          MON => 100, TUE => 110, WED => 105, THU => 115, FRI => 125
        })
        benchmark = ::Benchmark.create!(instrument: spy, name: "S&P 500 (SPY)")
        portfolio = create_portfolio(benchmark: benchmark)

        aapl = create_instrument(symbol: "AAPL")
        # A dip in the middle so drawdown is non-zero and peaks BEFORE the close.
        seed_prices(aapl, { MON => 100, TUE => 150, WED => 120, THU => 140, FRI => 150 })
        buy!(portfolio, aapl, on: MON, shares: "10", price: "100")

        summary = get_summary(portfolio)
        assert_response :ok

        assert_equal SUMMARY_KEYS.sort, summary.keys.sort
        assert_equal "1500.0", summary["current_value"]        # 10 x 150
        assert_equal "1000.0", summary["net_deposits"]         # 10 x 100
        assert_equal "500.0", summary["total_return"]
        assert_equal "0.5", summary["total_return_pct"]
        # SPY: $1000 buys 10 shares @ 100 -> 10 x 125 = 1250 -> +25%
        assert_equal "0.25", summary["benchmark_return_pct"]
        assert_equal "0.25", summary["vs_benchmark_edge_pct"]  # 0.5 - 0.25
        # portfolio peaked at 1500 (TUE) then dipped to 1200 (WED): -20%.
        assert_equal "-0.2", summary["max_drawdown_pct"]
        assert_equal "2026-07-10", summary["as_of"]
      end

      test "without a benchmark the benchmark tiles are null" do
        create_trading_days(MON, FRI)
        portfolio = create_portfolio # no benchmark
        aapl = create_instrument(symbol: "AAPL")
        seed_prices(aapl, { MON => 100, FRI => 120 })
        buy!(portfolio, aapl, on: MON, shares: "1", price: "100")

        summary = get_summary(portfolio)

        assert_equal "0.2", summary["total_return_pct"]
        assert_nil summary["benchmark_return_pct"]
        assert_nil summary["vs_benchmark_edge_pct"]
      end
    end
  end
end
