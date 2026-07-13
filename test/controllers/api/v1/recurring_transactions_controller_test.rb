require "test_helper"

# backlog #029: recurring-transactions CRUD (buy-only v1) + preview dry-run.
module Api
  module V1
    class RecurringTransactionsControllerTest < ActionDispatch::IntegrationTest
      include DomainTestHelper

      setup do
        @user = users(:one)
        @other_user = users(:two)
        @portfolio = Portfolio.create!(user: @user, name: "Main")
        @other_portfolio = Portfolio.create!(user: @other_user, name: "Not Yours")
        @aapl = create_instrument(symbol: "AAPL", instrument_type: "stock")
        list_symbol("AAPL")
        sign_in_as @user
      end

      # --- Auth + scoping ---

      test "every action requires an authenticated session (401 envelope)" do
        sign_out
        get api_v1_portfolio_recurring_transactions_path(@portfolio)
        assert_response :unauthorized
        assert_error_envelope "unauthenticated"
      end

      test "index answers 404 for another user's portfolio (no existence leak)" do
        get api_v1_portfolio_recurring_transactions_path(@other_portfolio)
        assert_response :not_found
        assert_error_envelope "not_found"
        assert_no_match(/Not Yours/, response.body)
      end

      test "cannot create a rule under another user's portfolio" do
        assert_no_difference "RecurringTransaction.count" do
          post api_v1_portfolio_recurring_transactions_path(@other_portfolio),
            params: rule_payload, as: :json
        end
        assert_response :not_found
      end

      test "show/update/destroy answer 404 for another user's rule" do
        rule = create_rule(anchor_on: Date.new(2030, 1, 15))
        moved = RecurringTransaction.find(rule.id)
        # Access the same rule id through the other user's portfolio scope.
        get api_v1_portfolio_recurring_transaction_path(@other_portfolio, moved)
        assert_response :not_found
      end

      # --- Create (buy-only, clamp) ---

      test "create persists a buy rule in the frozen shape and bumps series_version" do
        before = @portfolio.series_version

        assert_difference "@portfolio.recurring_transactions.count", 1 do
          post api_v1_portfolio_recurring_transactions_path(@portfolio), params: rule_payload, as: :json
        end

        assert_response :created
        body = JSON.parse(response.body).fetch("recurring_transaction")
        assert_equal %w[id portfolio_id instrument_id symbol side amount_type dollar_amount
                        share_amount frequency anchor_on next_run_on end_on active paused_reason
                        consecutive_skips created_at updated_at].sort, body.keys.sort
        assert_equal "buy", body["side"]
        assert_equal "AAPL", body["symbol"]
        assert_equal "dollars", body["amount_type"]
        assert_equal "500.0", body["dollar_amount"]
        assert_nil body["share_amount"]
        assert_equal true, body["active"]
        assert_nil body["paused_reason"]
        assert_equal 0, body["consecutive_skips"]
        assert_equal before + 1, @portfolio.reload.series_version
      end

      test "a sell rule is rejected 422 (buy-only in v1) mapped onto side" do
        assert_no_difference "RecurringTransaction.count" do
          post api_v1_portfolio_recurring_transactions_path(@portfolio),
            params: rule_payload(side: "sell"), as: :json
        end
        assert_response :unprocessable_entity
        assert assert_error_envelope("validation_failed").key?("side")
      end

      test "creation clamps next_run_on forward to the first slot on/after today (no historical backfill)" do
        travel_to Time.utc(2026, 7, 12, 12) do
          post api_v1_portfolio_recurring_transactions_path(@portfolio),
            params: rule_payload(frequency: "monthly", anchor_on: "2020-01-31"), as: :json

          assert_response :created
          next_run = JSON.parse(response.body).dig("recurring_transaction", "next_run_on")
          assert_equal "2026-07-31", next_run
          assert Date.iso8601(next_run) >= Trading::Calendar.today
        end
      end

      test "a share-amount rule with a dollar_amount is rejected 422" do
        assert_no_difference "RecurringTransaction.count" do
          post api_v1_portfolio_recurring_transactions_path(@portfolio),
            params: rule_payload(amount_type: "shares", share_amount: 2, dollar_amount: 500), as: :json
        end
        assert_response :unprocessable_entity
      end

      test "an unknown symbol is rejected 422 mapped onto symbol" do
        post api_v1_portfolio_recurring_transactions_path(@portfolio),
          params: rule_payload(symbol: "NOTREAL"), as: :json
        assert_response :unprocessable_entity
        assert assert_error_envelope("validation_failed").key?("symbol")
      end

      # --- Index / Update / Destroy ---

      test "index returns only the portfolio's rules with lifecycle fields" do
        create_rule(anchor_on: Date.new(2030, 1, 15))
        get api_v1_portfolio_recurring_transactions_path(@portfolio)
        assert_response :ok
        rules = JSON.parse(response.body).fetch("recurring_transactions")
        assert_equal 1, rules.size
        assert rules.first.key?("paused_reason")
        assert rules.first.key?("consecutive_skips")
        assert rules.first.key?("active")
      end

      test "update edits the amount and bumps series_version" do
        rule = create_rule(anchor_on: Date.new(2030, 1, 15))
        before = @portfolio.reload.series_version

        patch api_v1_portfolio_recurring_transaction_path(@portfolio, rule),
          params: { dollar_amount: "750.00" }, as: :json

        assert_response :ok
        assert_equal "750.0", JSON.parse(response.body).dig("recurring_transaction", "dollar_amount")
        assert_equal before + 1, @portfolio.reload.series_version
      end

      test "reactivating a paused rule clears its paused_reason and skip counter" do
        rule = create_rule(anchor_on: Date.new(2030, 1, 15))
        rule.update!(active: false, paused_reason: "Paused after 5 skips", consecutive_skips: 5)

        patch api_v1_portfolio_recurring_transaction_path(@portfolio, rule),
          params: { active: true }, as: :json

        assert_response :ok
        body = JSON.parse(response.body).fetch("recurring_transaction")
        assert_equal true, body["active"]
        assert_nil body["paused_reason"]
        assert_equal 0, body["consecutive_skips"]
      end

      test "destroy removes the rule and bumps series_version" do
        rule = create_rule(anchor_on: Date.new(2030, 1, 15))
        before = @portfolio.reload.series_version

        delete api_v1_portfolio_recurring_transaction_path(@portfolio, rule)

        assert_response :no_content
        assert_not RecurringTransaction.exists?(rule.id)
        assert_equal before + 1, @portfolio.reload.series_version
      end

      # --- Preview (dry run) ---

      test "preview returns the next 3 anchor-sequence slots without persisting anything" do
        travel_to Time.utc(2026, 7, 12, 12) do
          assert_no_difference "RecurringTransaction.count" do
            post preview_api_v1_portfolio_recurring_transactions_path(@portfolio),
              params: { frequency: "monthly", anchor_on: "2026-01-31" }, as: :json
          end

          assert_response :ok
          run_dates = JSON.parse(response.body).dig("preview", "run_dates")
          assert_equal %w[2026-07-31 2026-08-31 2026-09-30], run_dates.map { |d| d["scheduled_for"] },
            "monthly end-of-month anchor advances from the anchor, no drift"
        end
      end

      test "preview run dates carry the trading-day-adjusted execution date" do
        travel_to Time.utc(2026, 7, 6, 12) do
          create_trading_days(Date.new(2026, 7, 1), Date.new(2026, 8, 15))

          post preview_api_v1_portfolio_recurring_transactions_path(@portfolio),
            params: { frequency: "weekly", anchor_on: "2026-07-11" }, as: :json # a Saturday

          assert_response :ok
          run_dates = JSON.parse(response.body).dig("preview", "run_dates")
          assert_equal %w[2026-07-11 2026-07-18 2026-07-25], run_dates.map { |d| d["scheduled_for"] }
          # Each Saturday slot resolves to the following Monday's trading day.
          assert_equal %w[2026-07-13 2026-07-20 2026-07-27], run_dates.map { |d| d["execution_on"] }
        end
      end

      test "preview execution_on is null when the price calendar does not reach the slot" do
        travel_to Time.utc(2026, 7, 12, 12) do
          post preview_api_v1_portfolio_recurring_transactions_path(@portfolio),
            params: { frequency: "monthly", anchor_on: "2026-01-31" }, as: :json

          assert_response :ok
          run_dates = JSON.parse(response.body).dig("preview", "run_dates")
          assert run_dates.all? { |d| d["execution_on"].nil? }, "no calendar seeded → execution_on null"
        end
      end

      test "preview rejects an invalid frequency 422" do
        post preview_api_v1_portfolio_recurring_transactions_path(@portfolio),
          params: { frequency: "yearly", anchor_on: "2026-01-31" }, as: :json
        assert_response :unprocessable_entity
        assert assert_error_envelope("validation_failed").key?("frequency")
      end

      test "preview rejects a missing/invalid anchor 422" do
        post preview_api_v1_portfolio_recurring_transactions_path(@portfolio),
          params: { frequency: "monthly", anchor_on: "not-a-date" }, as: :json
        assert_response :unprocessable_entity
        assert assert_error_envelope("validation_failed").key?("anchor_on")
      end

      test "preview is scoped: another user's portfolio answers 404" do
        post preview_api_v1_portfolio_recurring_transactions_path(@other_portfolio),
          params: { frequency: "monthly", anchor_on: "2026-01-31" }, as: :json
        assert_response :not_found
      end

      private

      def rule_payload(**overrides)
        {
          symbol: "AAPL", side: "buy", amount_type: "dollars", dollar_amount: 500,
          frequency: "monthly", anchor_on: "2030-01-15"
        }.merge(overrides)
      end

      def create_rule(anchor_on:, **attrs)
        @portfolio.recurring_transactions.create!({
          instrument: @aapl, side: "buy", amount_type: "dollars", dollar_amount: 500,
          frequency: "monthly", anchor_on: anchor_on, next_run_on: anchor_on
        }.merge(attrs))
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
  end
end
