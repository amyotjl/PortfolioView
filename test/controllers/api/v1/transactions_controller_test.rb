require "test_helper"

# backlog #028: transactions CRUD scoped to Current.user's portfolio, POST by
# symbol (directory-validated, USD/US-exchange only), with Positions::Validator
# enforced on every mutation.
module Api
  module V1
    class TransactionsControllerTest < ActionDispatch::IntegrationTest
      include DomainTestHelper

      setup do
        @user = users(:one)
        @other_user = users(:two)
        @portfolio = Portfolio.create!(user: @user, name: "Main")
        @other_portfolio = Portfolio.create!(user: @other_user, name: "Not Yours")
        @aapl = create_instrument(symbol: "AAPL", instrument_type: "stock")
        list_symbol("AAPL", asset_type: "Stock")
        sign_in_as @user
      end

      # --- Auth ---

      test "every action requires an authenticated session (401 envelope)" do
        sign_out
        [
          -> { get api_v1_portfolio_transactions_path(@portfolio) },
          -> { post api_v1_portfolio_transactions_path(@portfolio), params: { symbol: "AAPL" }, as: :json }
        ].each do |request|
          request.call
          assert_response :unauthorized
          assert_error_envelope "unauthenticated"
        end
      end

      # --- Scoping: cross-user is 404, never data, never 403 ---

      test "index answers 404 for another user's portfolio (no existence leak)" do
        get api_v1_portfolio_transactions_path(@other_portfolio)
        assert_response :not_found
        assert_error_envelope "not_found"
        assert_no_match(/Not Yours/, response.body)
      end

      test "index answers the identical 404 envelope for a nonexistent portfolio" do
        get api_v1_portfolio_transactions_path(id: 999_999, portfolio_id: 999_999)
        missing = response.body
        get api_v1_portfolio_transactions_path(@other_portfolio)
        assert_equal missing, response.body
      end

      test "cannot create a transaction under another user's portfolio" do
        assert_no_difference "Transaction.count" do
          post api_v1_portfolio_transactions_path(@other_portfolio),
            params: transaction_payload, as: :json
        end
        assert_response :not_found
      end

      test "cannot update or destroy a transaction via another user's portfolio scope" do
        tx = buy!(@portfolio, @aapl, on: Date.new(2024, 1, 5), shares: 10, price: 100)

        patch api_v1_portfolio_transaction_path(@other_portfolio, tx), params: { shares: 1 }, as: :json
        assert_response :not_found
        assert_equal 10, tx.reload.shares

        delete api_v1_portfolio_transaction_path(@other_portfolio, tx)
        assert_response :not_found
        assert Transaction.exists?(tx.id)
      end

      # --- Create by symbol ---

      test "create finds-or-creates the instrument by symbol and returns 201 in the frozen shape" do
        assert_difference "@portfolio.transactions.count", 1 do
          post api_v1_portfolio_transactions_path(@portfolio), params: transaction_payload, as: :json
        end

        assert_response :created
        body = JSON.parse(response.body).fetch("transaction")
        assert_equal %w[id portfolio_id instrument_id symbol side kind shares price fees
                        executed_on notes recurring_transaction_id created_at updated_at].sort,
          body.keys.sort
        assert_equal "AAPL", body["symbol"]
        assert_equal @aapl.id, body["instrument_id"]
        assert_equal "buy", body["side"]
        assert_equal "normal", body["kind"]
        # shares/price/fees serialized as strings, never floats
        assert_equal "10.0", body["shares"]
        assert_equal "150.25", body["price"]
        assert_equal "1.5", body["fees"]
        assert_kind_of String, body["shares"]
      end

      test "create with a lowercase symbol resolves to the canonical instrument (no duplicate)" do
        assert_no_difference "Instrument.count" do
          post api_v1_portfolio_transactions_path(@portfolio),
            params: transaction_payload(symbol: "aapl"), as: :json
        end
        assert_response :created
        assert_equal @aapl.id, JSON.parse(response.body).dig("transaction", "instrument_id")
      end

      test "create supports the dividend_reinvestment kind" do
        post api_v1_portfolio_transactions_path(@portfolio),
          params: transaction_payload(kind: "dividend_reinvestment"), as: :json
        assert_response :created
        assert_equal "dividend_reinvestment", JSON.parse(response.body).dig("transaction", "kind")
      end

      test "any successful create bumps the portfolio series_version" do
        before = @portfolio.series_version
        post api_v1_portfolio_transactions_path(@portfolio), params: transaction_payload, as: :json
        assert_response :created
        assert_equal before + 1, @portfolio.reload.series_version
      end

      # --- Symbol validation (USD/US-exchange directory) ---

      test "an unknown symbol not in the directory answers 422 mapped onto symbol" do
        assert_no_difference [ "Transaction.count", "Instrument.count" ] do
          post api_v1_portfolio_transactions_path(@portfolio),
            params: transaction_payload(symbol: "NOTREAL"), as: :json
        end
        assert_response :unprocessable_entity
        assert assert_error_envelope("validation_failed").key?("symbol")
      end

      test "a non-USD / non-US-exchange listing is rejected 422 (unsupported in v1)" do
        ListedInstrument.create!(symbol: "SHOP", name: "Shopify", exchange: "TSX",
                                 asset_type: "Stock", currency: "CAD")
        assert_no_difference "Instrument.count" do
          post api_v1_portfolio_transactions_path(@portfolio),
            params: transaction_payload(symbol: "SHOP"), as: :json
        end
        assert_response :unprocessable_entity
        assert assert_error_envelope("validation_failed").key?("symbol")
      end

      test "a new US-exchange symbol creates the instrument with the mapped type" do
        list_symbol("VOO", asset_type: "ETF", exchange: "NYSE ARCA")
        assert_difference "Instrument.count", 1 do
          post api_v1_portfolio_transactions_path(@portfolio),
            params: transaction_payload(symbol: "VOO"), as: :json
        end
        assert_response :created
        assert_equal "etf", Instrument.find_by!(symbol: "VOO").instrument_type
      end

      test "missing symbol answers 422 mapped onto symbol" do
        post api_v1_portfolio_transactions_path(@portfolio),
          params: transaction_payload.except(:symbol), as: :json
        assert_response :unprocessable_entity
        assert assert_error_envelope("validation_failed").key?("symbol")
      end

      # --- Field validation ---

      test "non-positive shares answers 422 mapped onto shares" do
        post api_v1_portfolio_transactions_path(@portfolio),
          params: transaction_payload(shares: 0), as: :json
        assert_response :unprocessable_entity
        assert assert_error_envelope("validation_failed").key?("shares")
      end

      # --- Positions::Validator integration ---

      test "oversell answers 422 in the envelope naming the first offending date" do
        buy!(@portfolio, @aapl, on: Date.new(2024, 1, 5), shares: 10, price: 100)

        assert_no_difference "Transaction.count" do
          post api_v1_portfolio_transactions_path(@portfolio),
            params: transaction_payload(side: "sell", shares: 15, executed_on: "2024-01-10"), as: :json
        end

        assert_response :unprocessable_entity
        details = assert_error_envelope("validation_failed")
        assert details.key?("base"), "position violation surfaces on base"
        assert_match(/2024-01-10/, details["base"].join)
        assert_match(/AAPL/, details["base"].join)
      end

      test "a backdated edit that strands a later sell answers 422 naming the offending date" do
        buy!(@portfolio, @aapl, on: Date.new(2024, 1, 5), shares: 10, price: 100)
        sell = sell!(@portfolio, @aapl, on: Date.new(2024, 1, 20), shares: 10, price: 120)

        # Shrinking the earlier buy to 4 shares strands the 10-share sell.
        patch api_v1_portfolio_transaction_path(@portfolio, buy_id_before(sell)),
          params: { shares: 4 }, as: :json

        assert_response :unprocessable_entity
        details = assert_error_envelope("validation_failed")
        assert_match(/2024-01-20/, details["base"].join)
      end

      test "a backdated delete that strands a later sell answers 422 and keeps the row" do
        buy = buy!(@portfolio, @aapl, on: Date.new(2024, 1, 5), shares: 10, price: 100)
        sell!(@portfolio, @aapl, on: Date.new(2024, 1, 20), shares: 10, price: 120)

        delete api_v1_portfolio_transaction_path(@portfolio, buy)

        assert_response :unprocessable_entity
        assert_match(/2024-01-20/, assert_error_envelope("validation_failed")["base"].join)
        assert Transaction.exists?(buy.id), "rejected delete must keep the row"
      end

      # --- Update / Destroy happy paths ---

      test "update edits fields and bumps series_version" do
        tx = buy!(@portfolio, @aapl, on: Date.new(2024, 1, 5), shares: 10, price: 100)
        before = @portfolio.reload.series_version

        patch api_v1_portfolio_transaction_path(@portfolio, tx),
          params: { price: "111.11", notes: "adjusted" }, as: :json

        assert_response :ok
        body = JSON.parse(response.body).fetch("transaction")
        assert_equal "111.11", body["price"]
        assert_equal "adjusted", body["notes"]
        assert_equal before + 1, @portfolio.reload.series_version
      end

      test "destroy removes the transaction and bumps series_version" do
        tx = buy!(@portfolio, @aapl, on: Date.new(2024, 1, 5), shares: 10, price: 100)
        before = @portfolio.reload.series_version

        delete api_v1_portfolio_transaction_path(@portfolio, tx)

        assert_response :no_content
        assert_not Transaction.exists?(tx.id)
        assert_equal before + 1, @portfolio.reload.series_version
      end

      # --- Index ---

      test "index returns the portfolio's transactions most-recent-first with pagination meta" do
        buy!(@portfolio, @aapl, on: Date.new(2024, 1, 5), shares: 1, price: 100)
        buy!(@portfolio, @aapl, on: Date.new(2024, 3, 5), shares: 1, price: 100)
        buy!(@portfolio, @aapl, on: Date.new(2024, 2, 5), shares: 1, price: 100)

        get api_v1_portfolio_transactions_path(@portfolio)

        assert_response :ok
        body = JSON.parse(response.body)
        dates = body.fetch("transactions").map { |t| t["executed_on"] }
        assert_equal %w[2024-03-05 2024-02-05 2024-01-05], dates
        assert_equal({ "page" => 1, "per_page" => 50, "total_count" => 3, "total_pages" => 1 },
          body.fetch("meta"))
      end

      test "index paginates via page and per_page" do
        5.times { |i| buy!(@portfolio, @aapl, on: Date.new(2024, 1, i + 1), shares: 1, price: 100) }

        get api_v1_portfolio_transactions_path(@portfolio), params: { page: 2, per_page: 2 }

        assert_response :ok
        body = JSON.parse(response.body)
        assert_equal 2, body.fetch("transactions").size
        assert_equal 2, body.dig("meta", "page")
        assert_equal 5, body.dig("meta", "total_count")
        assert_equal 3, body.dig("meta", "total_pages")
      end

      test "index does not leak another user's transactions" do
        buy!(@other_portfolio, @aapl, on: Date.new(2024, 1, 5), shares: 99, price: 100)
        get api_v1_portfolio_transactions_path(@portfolio)
        assert_response :ok
        assert_empty JSON.parse(response.body).fetch("transactions")
      end

      private

      def transaction_payload(**overrides)
        {
          symbol: "AAPL", side: "buy", kind: "normal",
          shares: 10, price: "150.25", fees: "1.50", executed_on: "2024-01-05",
          notes: "initial"
        }.merge(overrides)
      end

      # The earlier buy of the two transactions in the strand-a-sell fixtures.
      def buy_id_before(sell)
        @portfolio.transactions.where(side: "buy").order(:executed_on).first
      end

      def list_symbol(symbol, name: symbol, exchange: "NASDAQ", asset_type: "Stock", currency: "USD")
        ListedInstrument.find_or_create_by!(symbol: symbol, exchange: exchange) do |li|
          li.name = name
          li.asset_type = asset_type
          li.currency = currency
        end
      end

      def assert_error_envelope(code)
        error = JSON.parse(response.body).fetch("error")
        assert_equal code, error.fetch("code")
        assert_kind_of String, error.fetch("message")
        assert error.key?("details")
        error.fetch("details")
      end
    end

    # The find-or-create of a NEW symbol fires the Instrument after_create_commit
    # backfill + metadata jobs — verifiable only outside the transactional-test
    # wrapper (after_commit never fires on a rolled-back transaction).
    class TransactionsControllerJobEnqueueTest < ActionDispatch::IntegrationTest
      include ActiveJob::TestHelper
      include DomainTestHelper

      self.use_transactional_tests = false

      setup do
        @user = users(:one)
        @portfolio = Portfolio.create!(user: @user, name: "Enqueue")
        ListedInstrument.create!(symbol: "NVDA", name: "NVIDIA", exchange: "NASDAQ",
                                 asset_type: "Stock", currency: "USD")
        sign_in_as @user
      end

      teardown do
        Transaction.where(portfolio_id: @portfolio.id).delete_all
        Instrument.where(symbol: "NVDA").delete_all
        # This class runs OUTSIDE the transactional wrapper, so every row the
        # setup commits must be removed by hand — the ListedInstrument was
        # missing here and leaked permanently into the worker's test database,
        # intermittently failing Directory::ImportJobTest's whole-table
        # assertions (found by the #034 contract-suite runs).
        ListedInstrument.where(symbol: "NVDA").delete_all
        @portfolio.destroy
        Session.where(user_id: @user.id).delete_all
        clear_enqueued_jobs
      end

      test "first reference to a new symbol enqueues the backfill and metadata jobs" do
        assert_enqueued_with(job: Prices::BackfillInstrumentJob) do
          assert_enqueued_with(job: Instruments::MetadataJob) do
            post api_v1_portfolio_transactions_path(@portfolio),
              params: { symbol: "NVDA", side: "buy", shares: 1, price: 100, executed_on: "2024-01-05" },
              as: :json
          end
        end
        assert_response :created
      end
    end
  end
end
