require "test_helper"

# backlog #064: GET /portfolios/export and POST /portfolios/import.
module Api
  module V1
    class PortfolioTransfersControllerTest < ActionDispatch::IntegrationTest
      include DomainTestHelper

      setup do
        @user = users(:one)
        @other_user = users(:two)
        @aapl = create_instrument(symbol: "AAPL")
        @portfolio = create_portfolio(name: "Retirement", user: @user)
        buy!(@portfolio, @aapl, on: Date.new(2024, 1, 5), shares: "10", price: "150.25", fees: "4.95")
        sign_in_as @user
      end

      # --- Auth -----------------------------------------------------------------

      test "both endpoints require an authenticated session" do
        sign_out

        get export_api_v1_portfolios_path
        assert_response :unauthorized
        assert_equal "unauthenticated", error_code

        post import_api_v1_portfolios_path, params: { file: upload("{}") }
        assert_response :unauthorized
        assert_equal "unauthenticated", error_code
      end

      test "import requires a CSRF token like every other mutation" do
        # ActionDispatch::IntegrationTest disables forgery protection by default;
        # turn it on to prove this endpoint is covered by the same pair.
        with_forgery_protection do
          post import_api_v1_portfolios_path, params: { file: upload(native_file) }

          assert_response :forbidden
          assert_equal "invalid_csrf_token", error_code
        end
      end

      # --- Export ---------------------------------------------------------------

      test "export answers a JSON attachment with a filename" do
        get export_api_v1_portfolios_path

        assert_response :ok
        assert_equal "application/json", response.media_type
        assert_match(/\Aattachment;/, response.headers["Content-Disposition"])
        assert_match(/filename="portfolioview-portfolios-\d{8}-\d{6}\.json"/,
                     response.headers["Content-Disposition"])
      end

      test "the exported body is the native envelope for the current user only" do
        create_portfolio(name: "Not Yours", user: @other_user)

        get export_api_v1_portfolios_path
        body = JSON.parse(response.body)

        assert_equal Portfolios::Transfer::NATIVE_FORMAT, body["format"]
        assert_equal Portfolios::Transfer::NATIVE_VERSION_BASE, body["version"]
        assert_equal [ "Retirement" ], body["portfolios"].map { |p| p["name"] }
        assert_no_match(/Not Yours/, response.body)
      end

      test "export is pretty-printed so the downloaded file is human-readable" do
        get export_api_v1_portfolios_path

        assert_includes response.body, "\n  ", "a hand-inspectable file is the point of an export"
      end

      test "portfolio_ids narrows the export and ignores non-integer entries" do
        other = create_portfolio(name: "Growth", user: @user)

        get export_api_v1_portfolios_path, params: { portfolio_ids: [ other.id.to_s, "abc" ] }

        assert_response :ok
        assert_equal [ "Growth" ], JSON.parse(response.body)["portfolios"].map { |p| p["name"] }
      end

      test "an empty portfolio_ids array exports everything rather than erroring" do
        get export_api_v1_portfolios_path, params: { portfolio_ids: [] }

        assert_response :ok
        assert_equal [ "Retirement" ], JSON.parse(response.body)["portfolios"].map { |p| p["name"] }
      end

      # --- Import: happy path ---------------------------------------------------

      test "import ingests a native file and reports per portfolio" do
        assert_difference "@user.portfolios.count", 1 do
          post import_api_v1_portfolios_path, params: { file: upload(native_file(name: "Imported")) }
        end

        assert_response :ok
        report = JSON.parse(response.body).fetch("import")
        assert_equal Portfolios::Transfer::NATIVE_FORMAT, report["format"]
        assert_equal false, report["dry_run"]
        assert_equal 1, report.dig("totals", "portfolios_created")
        assert_equal 1, report.dig("totals", "transactions_created")

        row = report["portfolios"].sole
        assert_equal %w[name imported_as status transactions_created recurring_created cash_created
                        errors warnings].sort,
                     row.keys.sort, "the import report shape is part of the contract"
        assert_equal "created", row["status"]
        assert_equal "Imported", row["imported_as"]
      end

      test "import detects a holdings CSV from its CONTENT, not its filename" do
        post import_api_v1_portfolios_path,
             params: { file: upload(file_fixture("holdings_report.csv").read, filename: "anything.txt") }

        assert_response :ok
        report = JSON.parse(response.body).fetch("import")
        assert_equal Portfolios::Transfer::HOLDINGS_CSV_FORMAT, report["format"]
        assert_equal %w[RRSP TFSA], report["portfolios"].map { |p| p["name"] }.sort
      end

      test "import detects a broker ACTIVITY LEDGER and reports splits it recorded" do
        post import_api_v1_portfolios_path,
             params: { file: upload(file_fixture("activities_report.csv").read, filename: "anything.txt") }

        assert_response :ok
        report = JSON.parse(response.body).fetch("import")
        assert_equal Portfolios::Transfer::ACTIVITIES_CSV_FORMAT, report["format"]
        assert_equal %w[RRSP TFSA], report["portfolios"].map { |p| p["name"] }.sort
        assert_equal 11, report.dig("totals", "transactions_created")
        # The ledger's CorporateAction row becomes an instrument-global SplitEvent,
        # so the count lives on `totals`, not on a portfolio row.
        assert_equal 1, report.dig("totals", "splits_created")
      end

      test "an activity-ledger import reports the cash it ingested and the counts per account" do
        post import_api_v1_portfolios_path,
             params: { file: upload(file_fixture("activities_report.csv").read) }

        report = JSON.parse(response.body).fetch("import")
        warnings = report["warnings"]
        assert warnings.any? { |w| w.include?("recorded in the portfolio’s cash ledger") },
               "what happened to the deposits and dividends must reach the client, got: #{warnings.inspect}"
        assert warnings.any? { |w| w.include?("3.0:1 split") },
               "a DERIVED split ratio is an inference and must be disclosed"

        # The stale version of this test asserted the opposite ("not a cash
        # balance", "understates return"). Both statements were true only while
        # there was nowhere to put the cash.
        assert_no_match(/not a cash balance|understates return/, warnings.join(" "),
                        "the pre-#80 caveats are now false and must not be shipped to a user")

        # TFSA: 1 deposit + 1 dividend + 1 interest + 1 tax + 1 fee + 2 transfer
        # offsets. RRSP: 1 interest.
        counts = report["portfolios"].to_h { |p| [ p["name"], p["cash_created"] ] }
        assert_equal({ "TFSA" => 7, "RRSP" => 1 }, counts)
        assert_equal 8, report.dig("totals", "cash_created")
      end

      test "the activity ledger and the holdings snapshot are distinguished by content" do
        post import_api_v1_portfolios_path,
             params: { file: upload(file_fixture("holdings_report.csv").read) }
        assert_equal Portfolios::Transfer::HOLDINGS_CSV_FORMAT,
                     JSON.parse(response.body).dig("import", "format")

        post import_api_v1_portfolios_path,
             params: { file: upload(file_fixture("activities_report.csv").read) }
        assert_equal Portfolios::Transfer::ACTIVITIES_CSV_FORMAT,
                     JSON.parse(response.body).dig("import", "format")
      end

      test "a holdings CSV import surfaces its caveats as warnings" do
        post import_api_v1_portfolios_path,
             params: { file: upload(file_fixture("holdings_report.csv").read) }

        warnings = JSON.parse(response.body).dig("import", "warnings")
        assert warnings.any? { |w| w.include?("no trade history") },
               "the synthesized-history caveat must reach the client"
        assert warnings.any? { |w| w.include?("venue-suffixed") }
      end

      test "dry_run previews without writing" do
        assert_no_difference "@user.portfolios.count" do
          post import_api_v1_portfolios_path,
               params: { file: upload(native_file(name: "Preview")), dry_run: "true" }
        end

        assert_response :ok
        report = JSON.parse(response.body).fetch("import")
        assert_equal true, report["dry_run"]
        assert_equal 1, report.dig("totals", "portfolios_created")
      end

      test "on_conflict is honored" do
        post import_api_v1_portfolios_path,
             params: { file: upload(native_file(name: "Retirement")), on_conflict: "skip" }

        assert_response :ok
        assert_equal "skipped", JSON.parse(response.body).dig("import", "portfolios", 0, "status")
        assert_equal 1, @user.portfolios.count
      end

      test "import writes to the current user, never another" do
        post import_api_v1_portfolios_path, params: { file: upload(native_file(name: "Mine")) }

        assert_response :ok
        assert @user.portfolios.exists?(name: "Mine")
        assert_not @other_user.portfolios.exists?(name: "Mine")
      end

      # --- Import: bad input is 422 on `file`, never a 500 ----------------------

      test "a missing file answers 422 mapped onto the file field" do
        post import_api_v1_portfolios_path, params: {}

        assert_response :unprocessable_entity
        assert_equal "validation_failed", error_code
        assert_includes error_details.fetch("file").first, "required"
      end

      test "a non-file value in the file param answers 422, not a 500" do
        post import_api_v1_portfolios_path, params: { file: "just a string" }

        assert_response :unprocessable_entity
        assert error_details.key?("file")
      end

      test "an empty file answers 422" do
        post import_api_v1_portfolios_path, params: { file: upload("   \n  ") }

        assert_response :unprocessable_entity
        assert_includes error_details.fetch("file").first, "empty"
      end

      test "an unrecognizable file answers 422 naming both accepted formats" do
        post import_api_v1_portfolios_path, params: { file: upload("a,b,c\n1,2,3\n") }

        assert_response :unprocessable_entity
        message = error_details.fetch("file").first
        assert_includes message, "PortfolioView JSON export"
        assert_includes message, "holdings CSV"
      end

      test "malformed JSON answers 422, not a 500" do
        post import_api_v1_portfolios_path, params: { file: upload('{"format": ') }

        assert_response :unprocessable_entity
        assert_includes error_details.fetch("file").first, "not valid JSON"
      end

      test "a foreign format string answers 422" do
        post import_api_v1_portfolios_path,
             params: { file: upload(JSON.generate(format: "someone.else", version: 1, portfolios: [])) }

        assert_response :unprocessable_entity
        assert_includes error_details.fetch("file").first, "not a PortfolioView export"
      end

      test "an oversized file is rejected before parsing" do
        oversized = "{" + ("x" * Portfolios::Transfer::MAX_FILE_BYTES)

        post import_api_v1_portfolios_path, params: { file: upload(oversized) }

        assert_response :unprocessable_entity
        assert_includes error_details.fetch("file").first, "smaller than"
      end

      test "invalid UTF-8 bytes yield a parse error rather than an encoding 500" do
        post import_api_v1_portfolios_path, params: { file: upload("{\xC3\x28 invalid".b) }

        assert_response :unprocessable_entity
        assert error_details.key?("file")
      end

      test "a failed portfolio is reported in a 200 body, not as an error status" do
        # A partially successful bulk import is a RESULT, not a failure: the client
        # needs the per-portfolio detail, which an error envelope cannot carry.
        file = native_file(name: "Bad", transactions: [
          { symbol: "AAPL", side: "sell", kind: "normal", shares: "5", price: "100",
            fees: "0", executed_on: "2024-01-05" }
        ])

        post import_api_v1_portfolios_path, params: { file: upload(file) }

        assert_response :ok
        report = JSON.parse(response.body).fetch("import")
        assert_equal 1, report.dig("totals", "portfolios_failed")
        assert_not_empty report.dig("portfolios", 0, "errors")
      end

      private

      def upload(content, filename: "portfolios.json")
        Rack::Test::UploadedFile.new(StringIO.new(content), "application/octet-stream",
                                     original_filename: filename)
      end

      def native_file(name: "Imported", transactions: nil)
        transactions ||= [
          { symbol: "AAPL", side: "buy", kind: "normal", shares: "3", price: "100",
            fees: "0", executed_on: "2024-01-05", notes: nil }
        ]
        JSON.generate(
          format: Portfolios::Transfer::NATIVE_FORMAT,
          version: Portfolios::Transfer::NATIVE_VERSION_BASE,
          instruments: [ { symbol: "AAPL", name: "Apple Inc", instrument_type: "stock", currency: "USD" } ],
          portfolios: [ { name: name, benchmark: nil, transactions: transactions,
                          recurring_transactions: [] } ]
        )
      end

      def error_code = JSON.parse(response.body).dig("error", "code")
      def error_details = JSON.parse(response.body).dig("error", "details")

      def with_forgery_protection
        original = ActionController::Base.allow_forgery_protection
        ActionController::Base.allow_forgery_protection = true
        yield
      ensure
        ActionController::Base.allow_forgery_protection = original
      end
    end
  end
end
