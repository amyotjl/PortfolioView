require "test_helper"

# backlog #032: GET /api/v1/portfolios/:id/allocations — by_instrument +
# by_sector pies as-of latest, ETFs bucketed "ETF / Fund" (docs/PLAN.md
# § API contract).
module Api
  module V1
    class AllocationsControllerTest < ActionDispatch::IntegrationTest
      include DomainTestHelper

      MON = Date.new(2026, 7, 6)
      FRI = Date.new(2026, 7, 10)

      setup do
        @user = users(:one)
        sign_in_as @user
      end

      def get_allocations(portfolio)
        get allocations_api_v1_portfolio_path(portfolio)
        JSON.parse(response.body).fetch("allocations")
      end

      # --- Auth + scoping ---

      test "requires an authenticated session" do
        portfolio = create_portfolio
        sign_out
        get allocations_api_v1_portfolio_path(portfolio)
        assert_response :unauthorized
      end

      test "another user's portfolio is the uniform 404 envelope" do
        other = Portfolio.create!(user: users(:two), name: "Not Yours")
        get allocations_api_v1_portfolio_path(other)
        assert_response :not_found
        assert_equal "not_found", JSON.parse(response.body).dig("error", "code")
      end

      # --- Empty portfolio: well-formed empty payload ---

      test "an empty portfolio returns well-formed empty arrays, not an error" do
        create_trading_days(MON, FRI)
        allocations = get_allocations(create_portfolio)

        assert_response :ok
        assert_nil allocations["as_of"]
        assert_equal "0.0", allocations["total_value"]
        assert_equal [], allocations["by_instrument"]
        assert_equal [], allocations["by_sector"]
      end

      # --- by_instrument + by_sector with the ETF / Fund bucket ---

      test "returns by_instrument and by_sector with weights, ETFs bucketed 'ETF / Fund'" do
        create_trading_days(MON, FRI)
        portfolio = create_portfolio

        aapl = create_instrument(symbol: "AAPL")
        msft = create_instrument(symbol: "MSFT")
        voo  = create_instrument(symbol: "VOO", instrument_type: "etf")
        aapl.update!(sector: "Technology")
        msft.update!(sector: "Technology")
        voo.update!(sector: nil) # no sector -> ETF / Fund bucket

        seed_prices(aapl, { FRI => 150 })
        seed_prices(msft, { FRI => 200 })
        seed_prices(voo,  { FRI => 250 })
        buy!(portfolio, aapl, on: MON, shares: "10", price: "100") # 1500
        buy!(portfolio, msft, on: MON, shares: "4",  price: "100") # 800
        buy!(portfolio, voo,  on: MON, shares: "2",  price: "100") # 500

        allocations = get_allocations(portfolio)
        assert_response :ok

        assert_equal "2026-07-10", allocations["as_of"]
        assert_equal "2800.0", allocations["total_value"]

        by_instrument = allocations["by_instrument"]
        assert_equal %w[instrument_id symbol value weight].sort, by_instrument.first.keys.sort
        # ordered largest value first
        assert_equal %w[AAPL MSFT VOO], by_instrument.map { |s| s["symbol"] }
        assert_equal "1500.0", by_instrument.first["value"]
        assert_equal aapl.id, by_instrument.first["instrument_id"]

        by_sector = allocations["by_sector"]
        assert_equal %w[sector value weight].sort, by_sector.first.keys.sort
        assert_equal "Technology", by_sector.first["sector"] # 2300, largest
        assert_equal "2300.0", by_sector.first["value"]
        assert_equal "ETF / Fund", by_sector.last["sector"]  # VOO's nil sector
        assert_equal "500.0", by_sector.last["value"]

        # weights sum to 1 within rounding, on both breakdowns
        assert_in_delta 1.0, by_instrument.sum { |s| BigDecimal(s["weight"]) }, 0.0001
        assert_in_delta 1.0, by_sector.sum { |s| BigDecimal(s["weight"]) }, 0.0001
      end

      test "a fully sold-out position drops out and yields an empty payload" do
        create_trading_days(MON, FRI)
        portfolio = create_portfolio
        aapl = create_instrument(symbol: "AAPL")
        seed_prices(aapl, { MON => 100, FRI => 150 })
        buy!(portfolio, aapl, on: MON, shares: "5", price: "100")
        sell!(portfolio, aapl, on: FRI, shares: "5", price: "150")

        allocations = get_allocations(portfolio)

        assert_response :ok
        assert_equal [], allocations["by_instrument"]
        assert_equal "0.0", allocations["total_value"]
      end
    end
  end
end
