require "test_helper"

# issue #80: CRUD /api/v1/portfolios/:portfolio_id/cash_transactions — the signed
# wire contract, the balance meta, and the rule that negative cash is WARNED
# about and never rejected.
module Api
  module V1
    class CashTransactionsControllerTest < ActionDispatch::IntegrationTest
      include DomainTestHelper

      MON = Date.new(2026, 7, 6)
      TUE = Date.new(2026, 7, 7)
      WED = Date.new(2026, 7, 8)
      THU = Date.new(2026, 7, 9)
      FRI = Date.new(2026, 7, 10)

      ROW_KEYS = %w[id portfolio_id kind amount occurred_on notes created_at updated_at].freeze

      setup do
        @user = users(:one)
        sign_in_as @user
        create_trading_days(MON, FRI)
        @portfolio = create_portfolio
        @aapl = create_instrument(symbol: "AAPL")
        seed_prices(@aapl, { MON => "500", TUE => "500", WED => "500", THU => "500", FRI => "500" })
      end

      def post_cash(params, portfolio: @portfolio)
        post api_v1_portfolio_cash_transactions_path(portfolio), params: params, as: :json
        JSON.parse(response.body)
      end

      # --- Auth + scoping -------------------------------------------------------

      test "requires an authenticated session" do
        sign_out
        get api_v1_portfolio_cash_transactions_path(@portfolio)
        assert_response :unauthorized
      end

      test "another user's portfolio is the uniform 404 envelope on every verb" do
        other = Portfolio.create!(user: users(:two), name: "Not Yours")
        row = CashTransaction.create!(portfolio: other, kind: "deposit", amount: 100, occurred_on: MON)

        get api_v1_portfolio_cash_transactions_path(other)
        assert_response :not_found
        assert_equal "not_found", JSON.parse(response.body).dig("error", "code")

        patch api_v1_portfolio_cash_transaction_path(other, row), params: { amount: "1" }, as: :json
        assert_response :not_found

        delete api_v1_portfolio_cash_transaction_path(other, row)
        assert_response :not_found
        assert CashTransaction.exists?(row.id), "nothing of another user's may be touched"
      end

      # --- Create ---------------------------------------------------------------

      test "a deposit is created and echoed in the frozen shape with a signed amount string" do
        body = post_cash({ kind: "deposit", amount: "2500.50", occurred_on: MON.iso8601, notes: "payday" })

        assert_response :created
        row = body.fetch("cash_transaction")
        assert_equal ROW_KEYS.sort, row.keys.sort
        assert_equal @portfolio.id, row["portfolio_id"]
        assert_equal "deposit", row["kind"]
        assert_equal "2500.5", row["amount"]
        assert_equal "2026-07-06", row["occurred_on"]
        assert_equal "payday", row["notes"]
        assert_equal BigDecimal("2500.50"), @portfolio.cash_transactions.sole.amount
      end

      test "a withdrawal is stored and echoed NEGATIVE, exactly as sent" do
        body = post_cash({ kind: "withdrawal", amount: "-750.00", occurred_on: TUE.iso8601 })

        assert_response :created
        assert_equal "-750.0", body.dig("cash_transaction", "amount")
        assert_equal BigDecimal("-750.00"), @portfolio.cash_transactions.sole.amount
      end

      # --- The sign boundary: what the client must send -------------------------

      # THE BODY THE CASH DRAWER ACTUALLY POSTS, and the reason this test exists.
      #
      # An unsigned magnitude with kind: "withdrawal" is a CLIENT ERROR under the
      # settled contract, and a 422 on `amount` is the CORRECT server behaviour —
      # not a bug to be fixed here. The server takes `amount` with the sign it was
      # given and derives nothing from `kind`, because `tax` and `fee` are legally
      # either sign under one kind name (a withholding vs a refund, a charge vs a
      # reimbursement), so a kind-derived sign loses information for four of the six
      # kinds. Converting a form's unsigned magnitude into a signed amount is the
      # FRONTEND's job, at `toCashInput` in frontend/src/lib/cash.ts.
      #
      # It exists because the merge gate on #80 found the drawer could not record a
      # withdrawal at all — it posted exactly this body — while every controller
      # test here posted the already-signed form. The assertions were right and the
      # INPUTS were unrepresentative, so the suite was green against a request shape
      # no real client ever sends. That is the vacuous-coverage failure mode this
      # repo keeps getting bitten by; if the contract is ever revisited, this test
      # is the one that must be consciously changed rather than quietly passing.
      test "an UNSIGNED withdrawal magnitude — the body the drawer posts — is a 422 on amount, not a silent rewrite" do
        post_cash({ kind: "withdrawal", amount: "1500.00", occurred_on: TUE.iso8601 })

        assert_response :unprocessable_entity
        details = JSON.parse(response.body).dig("error", "details")
        assert details.key?("amount"), "the 422 must map onto the amount field the form can highlight"
        assert_equal [ "must be negative for a withdrawal" ], details.fetch("amount")
        assert_equal 0, @portfolio.cash_transactions.count, "and nothing is persisted"
      end

      # The mirror: the signed bodies the client is required to send. Both manual
      # kinds, both directions, in one place, so the boundary reads as a pair.
      test "the correctly SIGNED forms of both manual kinds are accepted" do
        post_cash({ kind: "deposit", amount: "1500.00", occurred_on: MON.iso8601 })
        assert_response :created
        assert_equal BigDecimal("1500"), BigDecimal(JSON.parse(response.body).dig("cash_transaction", "amount"))

        post_cash({ kind: "withdrawal", amount: "-1500.00", occurred_on: TUE.iso8601 })
        assert_response :created
        assert_equal BigDecimal("-1500"), BigDecimal(JSON.parse(response.body).dig("cash_transaction", "amount"))

        assert_equal [ BigDecimal("-1500"), BigDecimal("1500") ],
                     @portfolio.cash_transactions.order(:occurred_on).pluck(:amount).reverse
      end

      # THE PROPERTY THAT MAKES A KIND-DERIVED SIGN UNACCEPTABLE, pinned at the
      # HTTP layer. Each of the four internal kinds is legally EITHER sign, and
      # both directions must round-trip with the caller's sign intact:
      #
      #   interest      + paid on idle cash        - a reversal
      #   dividend_cash + cash dividend received   - a reversal/clawback
      #   tax           - withholding              + a refund
      #   fee           - account fee              + a reimbursement
      #
      # Any "simplification" that derives the sign from `kind` — a NATURAL_SIGN
      # map, a before_validation coercion, an `.abs` in the serializer — can
      # satisfy at most one column of this table and must fail here.
      test "all four internal kinds accept BOTH signs through the endpoint, sign intact" do
        matrix = {
          "interest" => %w[1.25 -1.25],
          "dividend_cash" => %w[12.34 -12.34],
          "tax" => %w[-3.50 42.75],
          "fee" => %w[-4.95 4.95]
        }

        matrix.each do |kind, amounts|
          amounts.each do |amount|
            body = post_cash({ kind: kind, amount: amount, occurred_on: MON.iso8601 })

            assert_response :created, "#{kind} #{amount} must be accepted: #{response.body}"
            row = body.fetch("cash_transaction")
            assert_equal kind, row.fetch("kind")
            assert_equal BigDecimal(amount), BigDecimal(row.fetch("amount")),
                         "#{kind} must echo #{amount} with its sign intact, not a kind-derived one"
            assert_equal BigDecimal(amount), CashTransaction.find(row.fetch("id")).amount,
                         "#{kind} must PERSIST #{amount} with its sign intact"
          end
        end

        assert_equal 8, @portfolio.cash_transactions.count
      end

      test "create carries the balance meta so a toast can report it immediately" do
        cash!(@portfolio, kind: "deposit", amount: "1000.00", on: MON)

        body = post_cash({ kind: "withdrawal", amount: "-250.00", occurred_on: TUE.iso8601 })

        assert_response :created
        meta = body.fetch("meta")
        assert_equal %w[cash_balance cash_negative cash_negative_since].sort, meta.keys.sort
        assert_equal "750.0", meta["cash_balance"]
        assert_equal false, meta["cash_negative"]
        assert_nil meta["cash_negative_since"]
      end

      # THE mechanized form of the owner's decision. A balance validation, a CHECK
      # or a clamp anywhere in the chain turns this 201 into a 422.
      test "a buy that drives cash negative is accepted, persisted, and merely FLAGGED" do
        cash!(@portfolio, kind: "deposit", amount: "100.00", on: MON)
        buy!(@portfolio, @aapl, on: TUE, shares: "1", price: "500")

        # Another withdrawal on top of an already-negative balance: still fine.
        body = post_cash({ kind: "withdrawal", amount: "-10.00", occurred_on: WED.iso8601 })

        assert_response :created
        assert_equal 2, @portfolio.cash_transactions.count
        meta = body.fetch("meta")
        assert_equal "-410.0", meta["cash_balance"], "100 in, 500 spent, 10 more out"
        assert_equal true, meta["cash_negative"]
        assert_equal TUE.iso8601, meta["cash_negative_since"], "the buy's effective trading day"
      end

      test "the /summary tile agrees with the meta the create returned" do
        post_cash({ kind: "deposit", amount: "100.00", occurred_on: MON.iso8601 })
        buy!(@portfolio, @aapl, on: TUE, shares: "1", price: "500")
        meta = post_cash({ kind: "withdrawal", amount: "-10.00", occurred_on: WED.iso8601 }).fetch("meta")

        get summary_api_v1_portfolio_path(@portfolio)
        summary = JSON.parse(response.body).fetch("summary")

        assert_equal meta["cash_balance"], summary["cash_balance"],
                     "the toast must not be able to contradict the tile"
        assert_equal meta["cash_negative_since"], summary["cash_negative_since"]
        assert_equal "cash", summary["deposit_basis"]
      end

      # --- Validation -----------------------------------------------------------

      test "a wrong sign for deposit/withdrawal is a 422 mapped onto amount, not a silent rewrite" do
        post_cash({ kind: "deposit", amount: "-500.00", occurred_on: MON.iso8601 })

        assert_response :unprocessable_entity
        details = JSON.parse(response.body).dig("error", "details")
        assert details.key?("amount"), "422 details map onto the amount field"
        assert_equal 0, @portfolio.cash_transactions.count
      end

      test "an unknown kind is a 422 mapped onto kind" do
        post_cash({ kind: "bonus", amount: "10.00", occurred_on: MON.iso8601 })

        assert_response :unprocessable_entity
        assert JSON.parse(response.body).dig("error", "details").key?("kind")
      end

      test "a non-numeric amount is a 422 mapped onto amount, never a cast to zero" do
        post_cash({ kind: "deposit", amount: "twenty", occurred_on: MON.iso8601 })

        assert_response :unprocessable_entity
        assert JSON.parse(response.body).dig("error", "details").key?("amount")
        assert_equal 0, @portfolio.cash_transactions.count
      end

      test "a missing amount is a 422 that says it cannot be blank" do
        post_cash({ kind: "deposit", occurred_on: MON.iso8601 })

        assert_response :unprocessable_entity
        assert JSON.parse(response.body).dig("error", "details").key?("amount")
      end

      test "a missing occurred_on is a 422 mapped onto occurred_on" do
        post_cash({ kind: "deposit", amount: "10.00" })

        assert_response :unprocessable_entity
        assert JSON.parse(response.body).dig("error", "details").key?("occurred_on")
      end

      # --- Index ----------------------------------------------------------------

      test "index is newest-first and paginated" do
        cash!(@portfolio, kind: "deposit", amount: "1.00", on: MON)
        cash!(@portfolio, kind: "deposit", amount: "2.00", on: WED)
        cash!(@portfolio, kind: "deposit", amount: "3.00", on: FRI)

        get api_v1_portfolio_cash_transactions_path(@portfolio, per_page: 2)
        body = JSON.parse(response.body)

        assert_response :ok
        assert_equal [ FRI.iso8601, WED.iso8601 ], body.fetch("cash_transactions").map { |r| r["occurred_on"] }
        assert_equal({ "page" => 1, "per_page" => 2, "total_count" => 3, "total_pages" => 2 }, body.fetch("meta"))

        get api_v1_portfolio_cash_transactions_path(@portfolio, per_page: 2, page: 2)
        assert_equal [ MON.iso8601 ], JSON.parse(response.body).fetch("cash_transactions").map { |r| r["occurred_on"] }
      end

      test "index scopes to the portfolio and returns a well-formed empty page" do
        other = create_portfolio(name: "Other")
        cash!(other, kind: "deposit", amount: "99.00", on: MON)

        get api_v1_portfolio_cash_transactions_path(@portfolio)
        body = JSON.parse(response.body)

        assert_response :ok
        assert_empty body.fetch("cash_transactions")
        assert_equal 0, body.dig("meta", "total_pages")
      end

      # --- Update / destroy -----------------------------------------------------

      test "update rewrites the amount and returns the fresh balance meta" do
        row = cash!(@portfolio, kind: "deposit", amount: "1000.00", on: MON)

        patch api_v1_portfolio_cash_transaction_path(@portfolio, row),
          params: { amount: "1500.00" }, as: :json
        body = JSON.parse(response.body)

        assert_response :ok
        assert_equal "1500.0", body.dig("cash_transaction", "amount")
        assert_equal "1500.0", body.dig("meta", "cash_balance")
        assert_equal BigDecimal("1500.00"), row.reload.amount
      end

      test "update to a sign its kind forbids is a 422, and the row is untouched" do
        row = cash!(@portfolio, kind: "deposit", amount: "1000.00", on: MON)

        patch api_v1_portfolio_cash_transaction_path(@portfolio, row),
          params: { amount: "-1000.00" }, as: :json

        assert_response :unprocessable_entity
        assert JSON.parse(response.body).dig("error", "details").key?("amount")
        assert_equal BigDecimal("1000.00"), row.reload.amount
      end

      test "destroy is 204 with no body and the row is gone" do
        row = cash!(@portfolio, kind: "deposit", amount: "1000.00", on: MON)

        delete api_v1_portfolio_cash_transaction_path(@portfolio, row)

        assert_response :no_content
        assert_predicate response.body, :empty?
        assert_not CashTransaction.exists?(row.id)
      end

      test "removing the last cash row puts the portfolio back on the trade basis" do
        row = cash!(@portfolio, kind: "deposit", amount: "1000.00", on: MON)
        buy!(@portfolio, @aapl, on: MON, shares: "1", price: "500")

        get summary_api_v1_portfolio_path(@portfolio)
        assert_equal "cash", JSON.parse(response.body).dig("summary", "deposit_basis")

        delete api_v1_portfolio_cash_transaction_path(@portfolio, row)
        assert_response :no_content

        get summary_api_v1_portfolio_path(@portfolio)
        summary = JSON.parse(response.body).fetch("summary")
        assert_equal "trades", summary["deposit_basis"]
        assert_nil summary["cash_balance"], "back to null, not 0.00"
      end

      # --- Cache invalidation ---------------------------------------------------

      test "a cash mutation bumps series_version and rotates the candles cache" do
        buy!(@portfolio, @aapl, on: MON, shares: "1", price: "500")
        params = { from: MON.iso8601, to: FRI.iso8601 }

        get candles_api_v1_portfolio_path(@portfolio, params)
        before = JSON.parse(response.body)
        assert_nil before.fetch("cash")

        version = @portfolio.reload.series_version
        post_cash({ kind: "deposit", amount: "1000.00", occurred_on: MON.iso8601 })
        assert_response :created
        assert_operator @portfolio.reload.series_version, :>, version

        get candles_api_v1_portfolio_path(@portfolio, params)
        after = JSON.parse(response.body)

        assert_not_equal before, after, "the cash row must not be served from the stale cache"
        assert_equal "cash", after.dig("meta", "flow_basis")
        assert_equal "500.0", after.fetch("cash").last["v"], "1,000 in, 500 spent on the buy"
      end
    end
  end
end
