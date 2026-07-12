require "test_helper"

# backlog #027: portfolios CRUD scoped to Current.user.
module Api
  module V1
    class PortfoliosControllerTest < ActionDispatch::IntegrationTest
      setup do
        @user = users(:one)
        @other_user = users(:two)
        @portfolio = Portfolio.create!(user: @user, name: "Retirement")
        @other_portfolio = Portfolio.create!(user: @other_user, name: "Not Yours")
        sign_in_as @user
      end

      # --- Auth required ---

      test "every portfolios action requires an authenticated session (401 envelope)" do
        sign_out

        [
          -> { get api_v1_portfolios_path },
          -> { get api_v1_portfolio_path(@portfolio) },
          -> { post api_v1_portfolios_path, params: { name: "X" }, as: :json },
          -> { patch api_v1_portfolio_path(@portfolio), params: { name: "X" }, as: :json },
          -> { delete api_v1_portfolio_path(@portfolio) }
        ].each do |request|
          request.call
          assert_response :unauthorized
          assert_error_envelope "unauthenticated"
        end
      end

      # --- Scoping: cross-user access is 404, never 403, never data ---

      test "index returns only the current user's portfolios in the frozen shape" do
        get api_v1_portfolios_path

        assert_response :ok
        portfolios = JSON.parse(response.body).fetch("portfolios")
        assert_equal [ "Retirement" ], portfolios.map { |p| p["name"] }
        assert_equal %w[id name benchmark_id series_version created_at updated_at].sort,
          portfolios.first.keys.sort,
          "portfolio items must match the frozen contract shape"
        assert_equal 1, portfolios.first["series_version"]
      end

      test "show answers 404 envelope for another user's portfolio (no existence leak)" do
        get api_v1_portfolio_path(@other_portfolio)

        assert_response :not_found
        assert_error_envelope "not_found"
        assert_no_match(/Not Yours/, response.body)
      end

      test "show answers the identical 404 envelope for a nonexistent id" do
        get api_v1_portfolio_path(id: 999_999)
        missing_body = response.body

        get api_v1_portfolio_path(@other_portfolio)

        assert_equal missing_body, response.body,
          "cross-user and nonexistent must be indistinguishable"
      end

      test "update and destroy answer 404 for another user's portfolio and change nothing" do
        patch api_v1_portfolio_path(@other_portfolio), params: { name: "Hijacked" }, as: :json
        assert_response :not_found
        assert_error_envelope "not_found"
        assert_equal "Not Yours", @other_portfolio.reload.name

        delete api_v1_portfolio_path(@other_portfolio)
        assert_response :not_found
        assert Portfolio.exists?(@other_portfolio.id), "cross-user delete must not delete"
      end

      # --- Show / Create ---

      test "show returns the portfolio" do
        get api_v1_portfolio_path(@portfolio)

        assert_response :ok
        assert_equal "Retirement", JSON.parse(response.body).dig("portfolio", "name")
      end

      test "create persists a portfolio for the current user and returns 201" do
        benchmark = curated_benchmark

        assert_difference "@user.portfolios.count", 1 do
          post api_v1_portfolios_path, params: { name: "Growth", benchmark_id: benchmark.id }, as: :json
        end

        assert_response :created
        body = JSON.parse(response.body).fetch("portfolio")
        assert_equal "Growth", body["name"]
        assert_equal benchmark.id, body["benchmark_id"]
        assert_equal 1, body["series_version"]
        assert_equal @user, Portfolio.find(body["id"]).user
      end

      test "create without a benchmark is allowed (benchmark is optional)" do
        post api_v1_portfolios_path, params: { name: "Cash Account" }, as: :json

        assert_response :created
        assert_nil JSON.parse(response.body).dig("portfolio", "benchmark_id")
      end

      # --- Validation mapping (422 details onto form fields) ---

      test "duplicate portfolio name answers 422 mapped onto the name field" do
        assert_no_difference "Portfolio.count" do
          post api_v1_portfolios_path, params: { name: "Retirement" }, as: :json
        end

        assert_response :unprocessable_entity
        details = assert_error_envelope("validation_failed")
        assert details.key?("name"), "422 details must map onto the name field"
      end

      test "the same name as another user's portfolio is allowed (uniqueness is per user)" do
        post api_v1_portfolios_path, params: { name: "Not Yours" }, as: :json

        assert_response :created
      end

      test "missing name answers 422 mapped onto the name field" do
        post api_v1_portfolios_path, params: { name: "" }, as: :json

        assert_response :unprocessable_entity
        details = assert_error_envelope("validation_failed")
        assert details.key?("name")
      end

      test "create with an unknown benchmark_id answers 422 mapped onto benchmark_id, never an FK 500" do
        assert_no_difference "Portfolio.count" do
          post api_v1_portfolios_path, params: { name: "Growth", benchmark_id: 999_999 }, as: :json
        end

        assert_response :unprocessable_entity
        details = assert_error_envelope("validation_failed")
        assert details.key?("benchmark_id"), "422 details must map onto the benchmark_id field"
      end

      test "update with an unknown benchmark_id answers 422 and keeps the old value" do
        benchmark = curated_benchmark
        @portfolio.update!(benchmark_id: benchmark.id)

        patch api_v1_portfolio_path(@portfolio), params: { benchmark_id: 999_999 }, as: :json

        assert_response :unprocessable_entity
        assert assert_error_envelope("validation_failed").key?("benchmark_id")
        assert_equal benchmark.id, @portfolio.reload.benchmark_id
      end

      # --- Update ---

      test "update renames the portfolio and can set the benchmark" do
        benchmark = curated_benchmark

        patch api_v1_portfolio_path(@portfolio),
          params: { name: "Nest Egg", benchmark_id: benchmark.id }, as: :json

        assert_response :ok
        body = JSON.parse(response.body).fetch("portfolio")
        assert_equal "Nest Egg", body["name"]
        assert_equal benchmark.id, body["benchmark_id"]
        assert_equal "Nest Egg", @portfolio.reload.name
      end

      test "renaming onto the user's other portfolio name answers 422 mapped onto name" do
        Portfolio.create!(user: @user, name: "Growth")

        patch api_v1_portfolio_path(@portfolio), params: { name: "Growth" }, as: :json

        assert_response :unprocessable_entity
        assert assert_error_envelope("validation_failed").key?("name")
        assert_equal "Retirement", @portfolio.reload.name
      end

      # --- Destroy (cascade) ---

      test "destroy removes the portfolio and its dependent transactions and recurring rules" do
        instrument = Instrument.create!(symbol: "AAPL", instrument_type: "stock", currency: "USD")
        transaction = @portfolio.transactions.create!(
          instrument: instrument, side: "buy", shares: 1, price: 100, executed_on: Date.new(2024, 1, 5)
        )
        rule = @portfolio.recurring_transactions.create!(
          instrument: instrument, amount_type: "dollars", dollar_amount: 100,
          frequency: "monthly", anchor_on: Date.new(2024, 1, 31), next_run_on: Date.new(2024, 1, 31)
        )

        delete api_v1_portfolio_path(@portfolio)

        assert_response :no_content
        assert_not Portfolio.exists?(@portfolio.id)
        assert_not Transaction.exists?(transaction.id), "dependent transactions must be removed"
        assert_not RecurringTransaction.exists?(rule.id), "dependent recurring rules must be removed"
      end

      private

      def curated_benchmark
        instrument = Instrument.create!(symbol: "SPY", instrument_type: "etf", currency: "USD")
        ::Benchmark.create!(instrument: instrument, name: "S&P 500 (SPY)")
      end

      # Asserts the frozen envelope shape and returns details for field checks.
      def assert_error_envelope(code)
        error = JSON.parse(response.body).fetch("error")
        assert_equal code, error.fetch("code")
        assert_kind_of String, error.fetch("message")
        assert error.key?("details"), "envelope must always carry details"
        error.fetch("details")
      end
    end
  end
end
