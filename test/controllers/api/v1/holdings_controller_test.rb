require "test_helper"

# backlog #030: holdings pre-flight endpoint (split-adjusted shares as of a date).
module Api
  module V1
    class HoldingsControllerTest < ActionDispatch::IntegrationTest
      include DomainTestHelper

      setup do
        @user = users(:one)
        @other_user = users(:two)
        @portfolio = Portfolio.create!(user: @user, name: "Main")
        @other_portfolio = Portfolio.create!(user: @other_user, name: "Not Yours")
        @aapl = create_instrument(symbol: "AAPL", instrument_type: "stock")
        sign_in_as @user
      end

      # --- Auth + scoping ---

      test "requires an authenticated session (401 envelope)" do
        sign_out
        get api_v1_portfolio_holdings_path(@portfolio), params: { instrument_id: @aapl.id }
        assert_response :unauthorized
        assert_error_envelope "unauthenticated"
      end

      test "another user's portfolio answers 404 (no existence leak)" do
        get api_v1_portfolio_holdings_path(@other_portfolio), params: { instrument_id: @aapl.id }
        assert_response :not_found
        assert_error_envelope "not_found"
      end

      # --- Core: split-adjusted shares as of a date ---

      test "returns the split-adjusted share count as of the given date, shares as a string" do
        create_trading_days(Date.new(2024, 1, 1), Date.new(2024, 12, 31))
        buy!(@portfolio, @aapl, on: Date.new(2024, 1, 5), shares: 10, price: 100)
        split!(@aapl, on: Date.new(2024, 6, 1), ratio: 2) # 10 -> 20 shares

        get api_v1_portfolio_holdings_path(@portfolio),
          params: { instrument_id: @aapl.id, as_of: "2024-12-31" }

        assert_response :ok
        holding = JSON.parse(response.body).fetch("holding")
        assert_equal %w[instrument_id as_of shares].sort, holding.keys.sort
        assert_equal @aapl.id, holding["instrument_id"]
        assert_equal "2024-12-31", holding["as_of"]
        assert_equal "20.0", holding["shares"]
        assert_kind_of String, holding["shares"]
      end

      test "as_of BEFORE a split is not yet split-adjusted" do
        create_trading_days(Date.new(2024, 1, 1), Date.new(2024, 12, 31))
        buy!(@portfolio, @aapl, on: Date.new(2024, 1, 5), shares: 10, price: 100)
        split!(@aapl, on: Date.new(2024, 6, 1), ratio: 2)

        get api_v1_portfolio_holdings_path(@portfolio),
          params: { instrument_id: @aapl.id, as_of: "2024-03-01" }

        assert_response :ok
        assert_equal "10.0", JSON.parse(response.body).dig("holding", "shares")
      end

      test "a weekend as_of resolves to the prior trading day's close position" do
        create_trading_days(Date.new(2024, 1, 1), Date.new(2024, 1, 31))
        buy!(@portfolio, @aapl, on: Date.new(2024, 1, 5), shares: 7, price: 100)

        # 2024-01-13 is a Saturday → effective day is Friday 2024-01-12.
        get api_v1_portfolio_holdings_path(@portfolio),
          params: { instrument_id: @aapl.id, as_of: "2024-01-13" }

        assert_response :ok
        holding = JSON.parse(response.body).fetch("holding")
        assert_equal "2024-01-13", holding["as_of"], "echoes the requested as_of"
        assert_equal "7.0", holding["shares"]
      end

      test "as_of defaults to today (America/New_York) when omitted" do
        travel_to Time.utc(2024, 3, 15, 12) do # NY: 2024-03-15 08:00 EDT
          create_trading_days(Date.new(2024, 3, 1), Date.new(2024, 3, 15))
          buy!(@portfolio, @aapl, on: Date.new(2024, 3, 5), shares: 3, price: 100)

          get api_v1_portfolio_holdings_path(@portfolio), params: { instrument_id: @aapl.id }

          assert_response :ok
          holding = JSON.parse(response.body).fetch("holding")
          assert_equal "2024-03-15", holding["as_of"]
          assert_equal "3.0", holding["shares"]
        end
      end

      # --- Zero-shares (never 404) ---

      test "an instrument with no position returns a well-formed zero-shares response" do
        create_trading_days(Date.new(2024, 1, 1), Date.new(2024, 1, 31))

        get api_v1_portfolio_holdings_path(@portfolio),
          params: { instrument_id: @aapl.id, as_of: "2024-01-15" }

        assert_response :ok
        assert_equal "0.0", JSON.parse(response.body).dig("holding", "shares")
      end

      test "an unknown instrument id returns zero shares, not 404" do
        create_trading_days(Date.new(2024, 1, 1), Date.new(2024, 1, 31))

        get api_v1_portfolio_holdings_path(@portfolio),
          params: { instrument_id: 999_999, as_of: "2024-01-15" }

        assert_response :ok
        assert_equal "0.0", JSON.parse(response.body).dig("holding", "shares")
      end

      test "a fully-sold-out position reads zero shares" do
        create_trading_days(Date.new(2024, 1, 1), Date.new(2024, 1, 31))
        buy!(@portfolio, @aapl, on: Date.new(2024, 1, 5), shares: 5, price: 100)
        sell!(@portfolio, @aapl, on: Date.new(2024, 1, 10), shares: 5, price: 120)

        get api_v1_portfolio_holdings_path(@portfolio),
          params: { instrument_id: @aapl.id, as_of: "2024-01-31" }

        assert_response :ok
        assert_equal "0.0", JSON.parse(response.body).dig("holding", "shares")
      end

      # --- Param validation ---

      test "a missing instrument_id answers 422 mapped onto the field" do
        get api_v1_portfolio_holdings_path(@portfolio), params: { as_of: "2024-01-15" }
        assert_response :unprocessable_entity
        assert assert_error_envelope("validation_failed").key?("instrument_id")
      end

      test "a malformed as_of answers 422 mapped onto the field" do
        get api_v1_portfolio_holdings_path(@portfolio),
          params: { instrument_id: @aapl.id, as_of: "not-a-date" }
        assert_response :unprocessable_entity
        assert assert_error_envelope("validation_failed").key?("as_of")
      end

      private

      def assert_error_envelope(code)
        error = JSON.parse(response.body).fetch("error")
        assert_equal code, error.fetch("code")
        assert_kind_of String, error.fetch("message")
        assert error.key?("details")
        error.fetch("details")
      end
    end
  end
end
