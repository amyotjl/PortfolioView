require "test_helper"

# backlog #034: cross-cutting request specs for the FROZEN API contract
# (docs/PLAN.md § "API contract (frozen)").
#
# The per-endpoint controller tests cover each endpoint's own behavior; THIS
# suite treats the API as a black box and locks the contract-level invariants
# a refactor could silently drift:
#
#   * every frozen endpoint exists and is exercised through the real
#     router + auth + CSRF stack (session bootstrap -> authed flows);
#   * ONE error envelope {error: {code, message, details}} — asserted with the
#     exact same key-set check across 401/403/404/422/429 from many endpoints;
#   * the CSRF pair (XSRF-TOKEN cookie <-> X-XSRF-TOKEN header) enforced on
#     every non-GET, never on GET;
#   * auth required on every /api/v1 route (programmatic route sweep, so a
#     future endpoint added without auth fails here);
#   * cross-user access answers a BYTE-IDENTICAL 404 envelope to the
#     nonexistent-id case on every portfolio-scoped route (no existence leak);
#   * exact response key sets for candles (bare + benchmark-as-line),
#     summary/allocations (wrapped), transactions/recurring/holdings — the
#     shapes the frontend zod schemas mirror — with money always serialized
#     as strings, never JSON floats;
#   * one full happy path: register(invite) -> create portfolio -> add
#     transactions -> candles/summary/allocations return mutually coherent
#     numbers, all with forgery protection ON like production.
module ApiContract
  # The frozen contract, verbatim (docs/PLAN.md § API contract). PUT aliases of
  # PATCH updates are swept too but the canonical list pins PATCH.
  #
  # POST /api/internal/jobs/daily_sync (M9/backlog #052, issue #56) is routed now
  # but deliberately absent from this list AND from the auth sweep below: it is
  # not a /api/v1 route, it is bearer-token guarded, and it is the one endpoint
  # that must answer without a session or a CSRF token. Its contract lives in
  # test/controllers/api/internal/jobs_controller_test.rb. Its session-
  # authenticated twin POST /api/v1/sync IS swept (auth-gated like everything
  # else); it is additive to the frozen list, exactly like /portfolios/export.
  FROZEN_ROUTES = [
    [ "GET",    "/api/v1/session" ],
    [ "POST",   "/api/v1/session" ],
    [ "DELETE", "/api/v1/session" ],
    [ "POST",   "/api/v1/registration" ],
    [ "GET",    "/api/v1/instruments/search" ],
    [ "GET",    "/api/v1/instruments/:id/price" ],
    [ "GET",    "/api/v1/benchmarks" ],
    [ "GET",    "/api/v1/portfolios" ],
    [ "POST",   "/api/v1/portfolios" ],
    [ "GET",    "/api/v1/portfolios/:id" ],
    [ "PATCH",  "/api/v1/portfolios/:id" ],
    [ "DELETE", "/api/v1/portfolios/:id" ],
    [ "GET",    "/api/v1/portfolios/:id/candles" ],
    [ "GET",    "/api/v1/portfolios/:id/summary" ],
    [ "GET",    "/api/v1/portfolios/:id/allocations" ],
    [ "GET",    "/api/v1/portfolios/:portfolio_id/holdings" ],
    [ "GET",    "/api/v1/portfolios/:portfolio_id/transactions" ],
    [ "POST",   "/api/v1/portfolios/:portfolio_id/transactions" ],
    [ "PATCH",  "/api/v1/portfolios/:portfolio_id/transactions/:id" ],
    [ "DELETE", "/api/v1/portfolios/:portfolio_id/transactions/:id" ],
    [ "GET",    "/api/v1/portfolios/:portfolio_id/recurring_transactions" ],
    [ "POST",   "/api/v1/portfolios/:portfolio_id/recurring_transactions" ],
    [ "POST",   "/api/v1/portfolios/:portfolio_id/recurring_transactions/preview" ],
    [ "GET",    "/api/v1/portfolios/:portfolio_id/recurring_transactions/:id" ],
    [ "PATCH",  "/api/v1/portfolios/:portfolio_id/recurring_transactions/:id" ],
    [ "DELETE", "/api/v1/portfolios/:portfolio_id/recurring_transactions/:id" ]
  ].freeze

  # The zod-mirrored key sets (exact, sorted). A key added or removed anywhere
  # breaks the matching schema in frontend/src — that is the point.
  PORTFOLIO_KEYS   = %w[id name benchmark_id series_version created_at updated_at].sort.freeze
  BENCHMARK_KEYS   = %w[id name symbol].sort.freeze
  SEARCH_KEYS      = %w[symbol name exchange asset_type currency].sort.freeze
  PRICE_KEYS       = %w[instrument_id date close].sort.freeze
  USER_KEYS        = %w[id email_address].sort.freeze
  HOLDING_KEYS     = %w[instrument_id as_of shares].sort.freeze
  TRANSACTION_KEYS = %w[id portfolio_id instrument_id symbol side kind shares price fees
                        executed_on notes recurring_transaction_id created_at updated_at].sort.freeze
  RECURRING_KEYS   = %w[id portfolio_id instrument_id symbol side amount_type dollar_amount
                        share_amount frequency anchor_on next_run_on end_on active
                        paused_reason consecutive_skips created_at updated_at].sort.freeze
  PAGINATION_KEYS  = %w[page per_page total_count total_pages].sort.freeze
  CANDLES_TOP_KEYS = %w[candles benchmark flows drawdown meta].sort.freeze
  CANDLE_KEYS      = %w[t o h l c].sort.freeze
  POINT_KEYS       = %w[t v].sort.freeze
  FLOW_KEYS        = %w[t net items].sort.freeze
  FLOW_ITEM_KEYS   = %w[ticker kind amount].sort.freeze
  META_KEYS        = %w[partial filled_dates benchmark_clamped approximation].sort.freeze
  BENCHMARK_LINE_KEYS = %w[symbol values].sort.freeze
  SUMMARY_KEYS     = %w[current_value net_deposits total_return total_return_pct
                        benchmark_return_pct vs_benchmark_edge_pct max_drawdown_pct as_of].sort.freeze
  ALLOCATIONS_KEYS = %w[as_of total_value by_instrument by_sector].sort.freeze
  BY_INSTRUMENT_KEYS = %w[instrument_id symbol sector value weight].sort.freeze
  BY_SECTOR_KEYS   = %w[sector value weight].sort.freeze
  PREVIEW_SLOT_KEYS = %w[scheduled_for execution_on].sort.freeze

  module Helpers
    # THE single-envelope assertion: the response is JSON whose top level is
    # exactly {"error" => {"code", "message", "details"}} — nothing more,
    # nothing less. Applied verbatim to every error status in the suite.
    # Returns the details map for field-level assertions.
    def assert_envelope(code = nil)
      assert_equal "application/json", response.media_type,
        "every error must be the JSON envelope, never HTML (#{response.status})"
      body = JSON.parse(response.body)
      assert_equal %w[error], body.keys, "error responses carry ONLY the envelope"
      error = body.fetch("error")
      assert_equal %w[code details message], error.keys.sort,
        "the envelope is exactly {code, message, details}"
      assert_kind_of String, error["code"]
      assert_kind_of String, error["message"]
      assert_kind_of Hash, error["details"], "details is a field map (or {})"
      assert_equal code, error["code"] if code
      error.fetch("details")
    end

    def assert_exact_keys(expected, hash, label)
      assert_equal expected, hash.keys.sort, "#{label}: exact frozen key set"
    end

    # Money crosses the boundary as a JSON string, never a float (numeric
    # discipline: docs/PLAN.md — all money/shares are numeric, never float).
    def assert_money_string(expected, actual, label)
      assert_kind_of String, actual, "#{label} must serialize as a string, not a JSON number"
      assert_equal BigDecimal(expected), BigDecimal(actual), label
    end

    def json = JSON.parse(response.body)

    def with_forgery_protection
      original = ActionController::Base.allow_forgery_protection
      ActionController::Base.allow_forgery_protection = true
      yield
    ensure
      ActionController::Base.allow_forgery_protection = original
    end

    def csrf_token_from_cookie
      raw = cookies["XSRF-TOKEN"]
      raw.include?("%") ? CGI.unescape(raw) : raw
    end

    def csrf_header
      { "X-XSRF-TOKEN" => csrf_token_from_cookie }
    end

    # Black-box login through the real stack: bootstrap for the CSRF cookie,
    # then POST the credentials echoing the token — exactly what the SPA does.
    def login_through_the_front_door!(email:, password: "password")
      get "/api/v1/session"
      post "/api/v1/session",
        params: { email_address: email, password: password },
        headers: csrf_header, as: :json
      assert_response :created
    end

    def list_symbol(symbol, name: symbol, exchange: "NASDAQ", asset_type: "Stock", currency: "USD")
      ListedInstrument.find_or_create_by!(symbol: symbol, exchange: exchange) do |li|
        li.name = name
        li.asset_type = asset_type
        li.currency = currency
      end
    end

    # Every /api/v1 route in the live router as [verb, path_spec].
    def live_api_routes
      Rails.application.routes.routes.filter_map do |route|
        spec = route.path.spec.to_s.sub("(.:format)", "")
        next unless spec.start_with?("/api/v1/")
        verb = route.verb.to_s
        next if verb.blank?
        [ verb, spec ]
      end.uniq.sort
    end
  end

  # ---------------------------------------------------------------------------
  # 1. Every frozen endpoint exists, and every /api/v1 route requires auth.
  # ---------------------------------------------------------------------------
  class RouterContractTest < ActionDispatch::IntegrationTest
    include Helpers

    test "every endpoint of the frozen contract is routed" do
      routes = live_api_routes
      FROZEN_ROUTES.each do |verb, spec|
        assert_includes routes, [ verb, spec ],
          "frozen endpoint missing from the router: #{verb} #{spec}"
      end
    end

    test "every /api/v1 route answers the 401 envelope when unauthenticated" do
      # The only routes that answer something other than 401 "unauthenticated"
      # to an anonymous caller, with the code they answer instead. Everything
      # else — including any endpoint added later — must be auth-gated.
      public_entry_points = {
        [ "POST", "/api/v1/session" ]      => [ 401, "invalid_credentials" ],
        [ "POST", "/api/v1/registration" ] => [ 422, "invalid_invite_code" ]
      }

      routes = live_api_routes
      assert_operator routes.size, :>=, FROZEN_ROUTES.size, "route sweep must cover the whole contract"

      routes.each do |verb, spec|
        path = spec.gsub(/:\w+/, "1")
        send(verb.downcase, path, as: :json)

        expected_status, expected_code = public_entry_points.fetch([ verb, spec ], [ 401, "unauthenticated" ])
        assert_equal expected_status, response.status,
          "#{verb} #{spec} must be auth-gated (or a declared public entry point)"
        assert_envelope expected_code
      end
    end
  end

  # ---------------------------------------------------------------------------
  # 2. The single error envelope, uniform across statuses and endpoints.
  # ---------------------------------------------------------------------------
  class ErrorEnvelopeUniformityTest < ActionDispatch::IntegrationTest
    include Helpers
    include DomainTestHelper

    setup do
      @user = users(:one)
      @other_portfolio = Portfolio.create!(user: users(:two), name: "Not Yours")
    end

    test "401 unauthenticated wears the envelope on GET, POST, PATCH and DELETE endpoints alike" do
      [
        -> { get "/api/v1/portfolios" },
        -> { get "/api/v1/benchmarks" },
        -> { post "/api/v1/portfolios", params: { name: "X" }, as: :json },
        -> { delete "/api/v1/session" }
      ].each do |request|
        request.call
        assert_response :unauthorized
        assert_envelope "unauthenticated"
      end
    end

    test "401 invalid_credentials wears the same envelope" do
      post "/api/v1/session", params: { email_address: @user.email_address, password: "wrong" }, as: :json
      assert_response :unauthorized
      assert_envelope "invalid_credentials"
    end

    test "404 wears the same envelope for cross-user records, unknown ids, and unmatched paths" do
      sign_in_as @user
      [
        -> { get "/api/v1/portfolios/#{@other_portfolio.id}" }, # cross-user
        -> { get "/api/v1/portfolios/999999999" },              # unknown id
        -> { get "/api/v1/instruments/999999999/price?date=2024-01-05" },
        -> { get "/api/v1/does/not/exist" },                    # unmatched /api path
        -> { post "/api/v1/nope", as: :json }                   # unmatched /api path, non-GET
      ].each do |request|
        request.call
        assert_response :not_found
        assert_envelope "not_found"
      end
    end

    # #59: the /api/* catch-all renders a read-only 404 envelope and mutates
    # nothing, so it skips forgery protection. A token-less non-GET to an
    # unmatched /api path must therefore be the 404 envelope — never the 403
    # (CSRF) that a REAL mutating endpoint answers (locked in CsrfPairContractTest),
    # and never the 422 HTML it produced before the skip.
    test "a token-less non-GET to an unmatched /api path is 404, not a CSRF 403, even with forgery protection ON" do
      with_forgery_protection do
        %i[post patch delete].each do |verb|
          send(verb, "/api/v1/does-not-exist", as: :json)
          assert_response :not_found, "#{verb.upcase} to an unmatched /api path must be 404, not a CSRF failure"
          assert_envelope "not_found"
        end

        get "/api/v1/does-not-exist" # GET is unchanged
        assert_response :not_found
        assert_envelope "not_found"
      end
    end

    test "422 wears the same envelope with details mapped onto fields, across endpoints" do
      sign_in_as @user
      portfolio = create_portfolio

      { -> { post "/api/v1/portfolios", params: { name: "" }, as: :json }                  => "name",
        -> { get "/api/v1/portfolios/#{portfolio.id}/candles?from=not-a-date" }            => "from",
        -> { get "/api/v1/portfolios/#{portfolio.id}/holdings" }                           => "instrument_id",
        -> { get "/api/v1/instruments/search?q=A" }                                        => "q",
        -> { post "/api/v1/portfolios/#{portfolio.id}/recurring_transactions/preview",
               params: { frequency: "yearly", anchor_on: "2026-01-31" }, as: :json }       => "frequency"
      }.each do |request, field|
        request.call
        assert_response :unprocessable_entity
        details = assert_envelope("validation_failed")
        assert details.key?(field), "422 details must map onto #{field}"
      end
    end

    test "422 invalid_invite_code wears the same envelope" do
      post "/api/v1/registration",
        params: { email_address: "x@example.com", password: "password123",
                  password_confirmation: "password123", invite_code: "definitely-wrong" },
        as: :json
      assert_response :unprocessable_entity
      assert assert_envelope("invalid_invite_code").key?("invite_code")
    end

    test "429 rate_limited wears the same envelope" do
      10.times do
        post "/api/v1/session", params: { email_address: @user.email_address, password: "wrong" }, as: :json
        assert_response :unauthorized
      end

      post "/api/v1/session", params: { email_address: @user.email_address, password: "password" }, as: :json

      assert_response :too_many_requests
      assert_envelope "rate_limited"
      assert_equal 0, Session.count, "a rate-limited login attempt must not create a session"
    end

    test "403 invalid_csrf_token wears the same envelope" do
      sign_in_as @user
      with_forgery_protection do
        post "/api/v1/portfolios", params: { name: "Blocked" }, as: :json
        assert_response :forbidden
        assert_envelope "invalid_csrf_token"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # 3. CSRF: the XSRF-TOKEN cookie <-> X-XSRF-TOKEN header pair on non-GET.
  # ---------------------------------------------------------------------------
  class CsrfPairContractTest < ActionDispatch::IntegrationTest
    include Helpers
    include DomainTestHelper

    setup do
      @user = users(:one)
      @portfolio = Portfolio.create!(user: @user, name: "Main")
      create_trading_days(Date.new(2024, 1, 1), Date.new(2024, 1, 31))
      @aapl = create_instrument(symbol: "AAPL")
      list_symbol("AAPL")
      seed_prices(@aapl, { Date.new(2024, 1, 5) => 100 })
      @tx = buy!(@portfolio, @aapl, on: Date.new(2024, 1, 5), shares: 10, price: 100)
      sign_in_as @user
    end

    test "non-GET without the X-XSRF-TOKEN header is rejected 403 on every mutating endpoint, with no side effect" do
      with_forgery_protection do
        probes = [
          [ -> { post "/api/v1/portfolios", params: { name: "Nope" }, as: :json },
            -> { assert_not Portfolio.exists?(name: "Nope") } ],
          [ -> { patch "/api/v1/portfolios/#{@portfolio.id}", params: { name: "Hijack" }, as: :json },
            -> { assert_equal "Main", @portfolio.reload.name } ],
          [ -> { delete "/api/v1/portfolios/#{@portfolio.id}" },
            -> { assert Portfolio.exists?(@portfolio.id) } ],
          [ -> { post "/api/v1/portfolios/#{@portfolio.id}/transactions",
                 params: { symbol: "AAPL", side: "buy", shares: 1, price: 100, executed_on: "2024-01-06" }, as: :json },
            -> { assert_equal 1, @portfolio.transactions.count } ],
          [ -> { delete "/api/v1/portfolios/#{@portfolio.id}/transactions/#{@tx.id}" },
            -> { assert Transaction.exists?(@tx.id) } ],
          [ -> { post "/api/v1/portfolios/#{@portfolio.id}/recurring_transactions/preview",
                 params: { frequency: "monthly", anchor_on: "2030-01-31" }, as: :json },
            -> { } ],
          [ -> { delete "/api/v1/session" },
            -> { assert_equal 1, Session.count, "the session must survive a forged logout" } ]
        ]

        probes.each do |request, side_effect_check|
          request.call
          assert_response :forbidden
          assert_envelope "invalid_csrf_token"
          side_effect_check.call
        end
      end
    end

    test "a garbage X-XSRF-TOKEN header is rejected 403" do
      with_forgery_protection do
        post "/api/v1/portfolios", params: { name: "Nope" },
          headers: { "X-XSRF-TOKEN" => "not-the-token" }, as: :json
        assert_response :forbidden
        assert_envelope "invalid_csrf_token"
      end
    end

    test "GET endpoints never require the CSRF header" do
      with_forgery_protection do
        get "/api/v1/portfolios"
        assert_response :ok
        get "/api/v1/portfolios/#{@portfolio.id}/candles"
        assert_response :ok
      end
    end

    test "echoing the XSRF-TOKEN cookie in X-XSRF-TOKEN authorizes the mutation" do
      with_forgery_protection do
        get "/api/v1/session" # any response refreshes the CSRF cookie

        post "/api/v1/portfolios", params: { name: "With Token" },
          headers: csrf_header, as: :json

        assert_response :created
        assert Portfolio.exists?(name: "With Token")
      end
    end

    test "every API response refreshes a readable (non-HttpOnly) XSRF-TOKEN cookie" do
      get "/api/v1/portfolios"
      assert_response :ok

      xsrf_line = Array(response.headers["set-cookie"]).flat_map { |v| v.split("\n") }
        .grep(/\AXSRF-TOKEN=/).first
      assert xsrf_line, "authed API responses must (re)set the XSRF-TOKEN cookie"
      assert_no_match(/httponly/i, xsrf_line, "the SPA must be able to read the CSRF cookie")
    end
  end

  # ---------------------------------------------------------------------------
  # 4. Cross-user scoping: byte-identical 404 on every portfolio-scoped route.
  # ---------------------------------------------------------------------------
  class CrossUserScopingSweepTest < ActionDispatch::IntegrationTest
    include Helpers
    include DomainTestHelper

    setup do
      @user = users(:one)
      other = users(:two)
      @other_portfolio = Portfolio.create!(user: other, name: "Not Yours")
      aapl = create_instrument(symbol: "AAPL")
      @other_tx = buy!(@other_portfolio, aapl, on: Date.new(2024, 1, 5), shares: 10, price: 100)
      @other_rule = @other_portfolio.recurring_transactions.create!(
        instrument: aapl, side: "buy", amount_type: "dollars", dollar_amount: 500,
        frequency: "monthly", anchor_on: Date.new(2030, 1, 15), next_run_on: Date.new(2030, 1, 15)
      )
      sign_in_as @user
    end

    test "every portfolio-scoped route answers a byte-identical 404 envelope for another user's records" do
      get "/api/v1/portfolios/999999999"
      assert_response :not_found
      canonical_404 = response.body

      scoped = live_api_routes.select do |_verb, spec|
        spec.include?(":portfolio_id") || spec.match?(%r{/portfolios/:id})
      end
      assert_operator scoped.size, :>=, 16, "the sweep must cover all portfolio-scoped routes"

      scoped.each do |verb, spec|
        path = spec
          .sub("/portfolios/:portfolio_id", "/portfolios/#{@other_portfolio.id}")
          .sub("/portfolios/:id", "/portfolios/#{@other_portfolio.id}")
          .sub("/transactions/:id", "/transactions/#{@other_tx.id}")
          .sub("/recurring_transactions/:id", "/recurring_transactions/#{@other_rule.id}")

        send(verb.downcase, path, as: :json)

        assert_response :not_found, "#{verb} #{spec} must 404 for another user's portfolio"
        assert_equal canonical_404, response.body,
          "#{verb} #{spec}: cross-user 404 must be byte-identical to the nonexistent-id 404 (no existence leak)"
      end

      assert_no_match(/Not Yours/, canonical_404)
      assert @other_portfolio.reload.persisted?
      assert Transaction.exists?(@other_tx.id), "the sweep's DELETEs must not have destroyed anything"
      assert RecurringTransaction.exists?(@other_rule.id)
    end
  end

  # ---------------------------------------------------------------------------
  # 5. Frozen response shapes (exact key sets) — what the zod schemas mirror.
  # ---------------------------------------------------------------------------
  class ResponseShapeContractTest < ActionDispatch::IntegrationTest
    include Helpers
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
      list_symbol("AAPL", name: "Apple Inc")
      seed_prices(@aapl, { MON => [ "100", "105", "95", "100" ], TUE => 150, WED => 120, THU => 140, FRI => 130 })
      buy!(@portfolio, @aapl, on: MON, shares: "10", price: "100", fees: "5")
    end

    test "session bootstrap is {user} with exactly {id, email_address}" do
      get "/api/v1/session"
      assert_response :ok
      assert_exact_keys %w[user], json, "session top level"
      assert_exact_keys USER_KEYS, json.fetch("user"), "user"
    end

    test "portfolios index/show/create wrap the frozen portfolio shape" do
      get "/api/v1/portfolios"
      assert_response :ok
      assert_exact_keys %w[portfolios], json, "index top level"
      assert_exact_keys PORTFOLIO_KEYS, json.fetch("portfolios").sole, "portfolio item"

      get "/api/v1/portfolios/#{@portfolio.id}"
      assert_response :ok
      assert_exact_keys %w[portfolio], json, "show top level"
      assert_exact_keys PORTFOLIO_KEYS, json.fetch("portfolio"), "portfolio"

      post "/api/v1/portfolios", params: { name: "Second" }, as: :json
      assert_response :created
      assert_exact_keys %w[portfolio], json, "create top level"
      assert_exact_keys PORTFOLIO_KEYS, json.fetch("portfolio"), "created portfolio"
    end

    test "benchmarks index carries exactly {id, name, symbol} per item" do
      get "/api/v1/benchmarks"
      assert_response :ok
      assert_exact_keys %w[benchmarks], json, "top level"
      assert_exact_keys BENCHMARK_KEYS, json.fetch("benchmarks").sole, "benchmark item"
    end

    test "instruments search carries the directory shape; price carries {instrument_id, date, close} with close as a string" do
      get "/api/v1/instruments/search?q=AAP"
      assert_response :ok
      assert_exact_keys %w[instruments], json, "search top level"
      assert_exact_keys SEARCH_KEYS, json.fetch("instruments").sole, "search item"

      get "/api/v1/instruments/#{@aapl.id}/price?date=#{THU.iso8601}"
      assert_response :ok
      assert_exact_keys %w[price], json, "price top level"
      price = json.fetch("price")
      assert_exact_keys PRICE_KEYS, price, "price"
      assert_money_string "140", price["close"], "close prefill"
    end

    test "transactions index is {transactions, meta(pagination)}; create wraps the frozen transaction shape with money as strings" do
      get "/api/v1/portfolios/#{@portfolio.id}/transactions"
      assert_response :ok
      assert_exact_keys %w[meta transactions], json, "index top level"
      assert_exact_keys TRANSACTION_KEYS, json.fetch("transactions").sole, "transaction item"
      assert_exact_keys PAGINATION_KEYS, json.fetch("meta"), "pagination meta"

      post "/api/v1/portfolios/#{@portfolio.id}/transactions",
        params: { symbol: "AAPL", side: "buy", shares: 2, price: "120.50", fees: "0.99",
                  executed_on: WED.iso8601 }, as: :json
      assert_response :created
      assert_exact_keys %w[transaction], json, "create top level"
      tx = json.fetch("transaction")
      assert_exact_keys TRANSACTION_KEYS, tx, "created transaction"
      assert_money_string "2",      tx["shares"], "shares"
      assert_money_string "120.50", tx["price"],  "price"
      assert_money_string "0.99",   tx["fees"],   "fees"
    end

    test "recurring index/create wrap the frozen rule shape; preview returns exactly 3 {scheduled_for, execution_on} slots" do
      post "/api/v1/portfolios/#{@portfolio.id}/recurring_transactions",
        params: { symbol: "AAPL", side: "buy", amount_type: "dollars", dollar_amount: 500,
                  frequency: "monthly", anchor_on: "2030-01-15" }, as: :json
      assert_response :created
      assert_exact_keys %w[recurring_transaction], json, "create top level"
      rule = json.fetch("recurring_transaction")
      assert_exact_keys RECURRING_KEYS, rule, "created rule"
      assert_money_string "500", rule["dollar_amount"], "dollar_amount"

      get "/api/v1/portfolios/#{@portfolio.id}/recurring_transactions"
      assert_response :ok
      assert_exact_keys %w[recurring_transactions], json, "index top level"
      assert_exact_keys RECURRING_KEYS, json.fetch("recurring_transactions").sole, "rule item"

      post "/api/v1/portfolios/#{@portfolio.id}/recurring_transactions/preview",
        params: { frequency: "monthly", anchor_on: "2030-01-31" }, as: :json
      assert_response :ok
      assert_exact_keys %w[preview], json, "preview top level"
      assert_exact_keys %w[run_dates], json.fetch("preview"), "preview"
      run_dates = json.dig("preview", "run_dates")
      assert_equal 3, run_dates.size, "preview returns exactly 3 run dates"
      run_dates.each { |slot| assert_exact_keys PREVIEW_SLOT_KEYS, slot, "preview slot" }
      assert_equal %w[2030-01-31 2030-02-28 2030-03-31], run_dates.map { |s| s["scheduled_for"] },
        "end-of-month anchor clamps without drift"
    end

    test "holdings pre-flight is {holding: {instrument_id, as_of, shares}} with shares as a string" do
      get "/api/v1/portfolios/#{@portfolio.id}/holdings",
        params: { instrument_id: @aapl.id, as_of: FRI.iso8601 }
      assert_response :ok
      assert_exact_keys %w[holding], json, "top level"
      holding = json.fetch("holding")
      assert_exact_keys HOLDING_KEYS, holding, "holding"
      assert_money_string "10", holding["shares"], "shares held"

      # #60: an as_of before the earliest trading day is a genuine zero position,
      # not the current holding.
      get "/api/v1/portfolios/#{@portfolio.id}/holdings",
        params: { instrument_id: @aapl.id, as_of: "2000-01-01" }
      assert_response :ok
      assert_equal "2000-01-01", json.dig("holding", "as_of"), "echoes the requested as_of"
      assert_money_string "0", json.dig("holding", "shares"), "far-past as_of is a zero position"
    end

    test "candles is exactly {candles, benchmark, flows, drawdown, meta}; bare requests carry benchmark: null" do
      get "/api/v1/portfolios/#{@portfolio.id}/candles",
        params: { from: MON.iso8601, to: FRI.iso8601 }
      assert_response :ok

      assert_exact_keys CANDLES_TOP_KEYS, json, "candles top level"
      assert_nil json.fetch("benchmark"), "benchmark must be null unless benchmark=true"

      candle = json.fetch("candles").first
      assert_exact_keys CANDLE_KEYS, candle, "candle"
      %w[o h l c].each { |k| assert_kind_of String, candle[k], "candle #{k} must be a string" }
      assert_money_string "1000", candle["c"], "MON close = 10 x 100"

      flow = json.fetch("flows").sole
      assert_exact_keys FLOW_KEYS, flow, "flow"
      assert_money_string "1005", flow["net"], "flow net includes the buy fee"
      assert_exact_keys FLOW_ITEM_KEYS, flow.fetch("items").sole, "flow item"

      drawdown_point = json.fetch("drawdown").first
      assert_exact_keys POINT_KEYS, drawdown_point, "drawdown point"

      assert_exact_keys META_KEYS, json.fetch("meta"), "meta carries exactly the four flags"
    end

    test "candles with benchmark=true carries the benchmark as a close-value LINE {symbol, values:[{t,v}]}, never candles" do
      get "/api/v1/portfolios/#{@portfolio.id}/candles",
        params: { from: MON.iso8601, to: FRI.iso8601, benchmark: true }
      assert_response :ok

      benchmark = json.fetch("benchmark")
      assert_exact_keys BENCHMARK_LINE_KEYS, benchmark, "benchmark line"
      assert_equal "SPY", benchmark["symbol"]
      benchmark.fetch("values").each do |point|
        assert_exact_keys POINT_KEYS, point, "benchmark point (a line, no o/h/l/c)"
        assert_kind_of String, point["v"], "benchmark values are money strings"
      end
    end

    test "summary is wrapped {summary} with exactly the eight lifetime tiles, money as strings" do
      get "/api/v1/portfolios/#{@portfolio.id}/summary"
      assert_response :ok
      assert_exact_keys %w[summary], json, "top level"
      summary = json.fetch("summary")
      assert_exact_keys SUMMARY_KEYS, summary, "summary tiles"
      assert_money_string "1300", summary["current_value"], "current_value = 10 x FRI 130"
      assert_money_string "1005", summary["net_deposits"], "net_deposits includes fees"
    end

    test "allocations is wrapped {allocations} with by_instrument and by_sector slices in the frozen shape" do
      get "/api/v1/portfolios/#{@portfolio.id}/allocations"
      assert_response :ok
      assert_exact_keys %w[allocations], json, "top level"
      allocations = json.fetch("allocations")
      assert_exact_keys ALLOCATIONS_KEYS, allocations, "allocations"

      slice = allocations.fetch("by_instrument").sole
      assert_exact_keys BY_INSTRUMENT_KEYS, slice, "by_instrument slice"
      assert_money_string "1300", slice["value"], "AAPL value"
      assert_money_string "1", slice["weight"], "single-holding weight"

      sector = allocations.fetch("by_sector").sole
      assert_exact_keys BY_SECTOR_KEYS, sector, "by_sector slice"
      assert_money_string "1300", sector["value"], "sector value"

      # The instrument slice's `sector` is the join key into by_sector — the
      # treemap's hierarchy depends on the two labels being byte-identical.
      assert_equal sector["sector"], slice["sector"], "by_instrument sector joins by_sector"
    end
  end

  # ---------------------------------------------------------------------------
  # 6. The full happy path, black-box, with forgery protection ON throughout.
  # ---------------------------------------------------------------------------
  class HappyPathTest < ActionDispatch::IntegrationTest
    include Helpers
    include DomainTestHelper

    INVITE_CODE = "contract-suite-invite".freeze

    MON = Date.new(2026, 7, 6)
    TUE = Date.new(2026, 7, 7)
    WED = Date.new(2026, 7, 8)
    THU = Date.new(2026, 7, 9)
    FRI = Date.new(2026, 7, 10)

    setup do
      @original_invite_code = ENV["INVITE_CODE"]
      ENV["INVITE_CODE"] = INVITE_CODE

      @spy = create_trading_days(MON, FRI, closes: { MON => 100, TUE => 110, WED => 105, THU => 115, FRI => 125 })
      @benchmark = ::Benchmark.create!(instrument: @spy, name: "S&P 500 (SPY)")
      list_symbol("AAPL", name: "Apple Inc")
      @aapl = create_instrument(symbol: "AAPL")
      # THU 20x140=2800 is the all-time peak; FRI 20x105=2100 is an exact -0.25 drawdown.
      seed_prices(@aapl, { MON => 100, TUE => 150, WED => 120, THU => 140, FRI => 105 })
    end

    teardown do
      ENV["INVITE_CODE"] = @original_invite_code
    end

    test "register -> create portfolio -> transact -> candles, summary and allocations agree with each other" do
      with_forgery_protection do
        # --- Bootstrap: 401 envelope but a usable CSRF cookie ---
        get "/api/v1/session"
        assert_response :unauthorized
        assert_envelope "unauthenticated"
        assert cookies["XSRF-TOKEN"].present?, "bootstrap must hand the SPA its CSRF token"

        # --- Register through the invite gate; signed in immediately ---
        post "/api/v1/registration",
          params: { email_address: "trader@example.com", password: "password123",
                    password_confirmation: "password123", invite_code: INVITE_CODE },
          headers: csrf_header, as: :json
        assert_response :created

        get "/api/v1/session"
        assert_response :ok
        assert_equal "trader@example.com", json.dig("user", "email_address")

        # --- Create the portfolio against the curated benchmark ---
        post "/api/v1/portfolios",
          params: { name: "First Portfolio", benchmark_id: @benchmark.id },
          headers: csrf_header, as: :json
        assert_response :created
        portfolio_id = json.dig("portfolio", "id")

        # --- The transaction-form flow: search the directory, prefill the close ---
        get "/api/v1/instruments/search?q=AAP"
        assert_response :ok
        assert_equal "AAPL", json.fetch("instruments").sole["symbol"]

        # --- Buy 10 AAPL @ 100 + $5 fee on MON ---
        post "/api/v1/portfolios/#{portfolio_id}/transactions",
          params: { symbol: "AAPL", side: "buy", shares: 10, price: "100", fees: "5",
                    executed_on: MON.iso8601 },
          headers: csrf_header, as: :json
        assert_response :created
        instrument_id = json.dig("transaction", "instrument_id")

        get "/api/v1/instruments/#{instrument_id}/price?date=#{WED.iso8601}"
        assert_response :ok
        assert_money_string "120", json.dig("price", "close"), "WED close prefill"

        # --- First look at the chart ---
        get "/api/v1/portfolios/#{portfolio_id}/candles",
          params: { from: MON.iso8601, to: FRI.iso8601, benchmark: true }
        assert_response :ok
        first_read = json
        assert_money_string "1050", first_read.fetch("candles").last["c"], "FRI close = 10 x 105"

        # --- Buy 10 more @ 120 on WED; the chart must not serve the stale cache ---
        post "/api/v1/portfolios/#{portfolio_id}/transactions",
          params: { symbol: "AAPL", side: "buy", shares: 10, price: "120",
                    executed_on: WED.iso8601 },
          headers: csrf_header, as: :json
        assert_response :created

        get "/api/v1/portfolios/#{portfolio_id}/candles",
          params: { from: MON.iso8601, to: FRI.iso8601, benchmark: true }
        assert_response :ok
        candles = json
        assert_not_equal first_read, candles, "a new transaction must rotate the candles cache"

        # Candles: 10 shares MON/TUE, 20 from WED.
        closes = candles.fetch("candles").map { |c| [ c["t"], c["c"] ] }.to_h
        assert_money_string "1000", closes.fetch(MON.iso8601), "MON 10 x 100"
        assert_money_string "1500", closes.fetch(TUE.iso8601), "TUE 10 x 150"
        assert_money_string "2400", closes.fetch(WED.iso8601), "WED 20 x 120"
        assert_money_string "2800", closes.fetch(THU.iso8601), "THU 20 x 140 (all-time peak)"
        assert_money_string "2100", closes.fetch(FRI.iso8601), "FRI 20 x 105"

        # Flows: one per buy date, fees included on buys.
        flows = candles.fetch("flows").map { |f| [ f["t"], f["net"] ] }.to_h
        assert_equal [ MON.iso8601, WED.iso8601 ], flows.keys.sort
        assert_money_string "1005", flows.fetch(MON.iso8601), "MON deposit includes the $5 fee"
        assert_money_string "1200", flows.fetch(WED.iso8601), "WED deposit"

        # Drawdown from the all-time peak: flat until THU's peak, then -25% on FRI.
        drawdown = candles.fetch("drawdown").map { |d| [ d["t"], d["v"] ] }.to_h
        assert_money_string "0", drawdown.fetch(THU.iso8601), "at the peak"
        assert_money_string "-0.25", drawdown.fetch(FRI.iso8601), "(2100 - 2800) / 2800"

        # Benchmark line: same-dollar flows into SPY, first point = MON deposit.
        benchmark = candles.fetch("benchmark")
        assert_equal "SPY", benchmark["symbol"]
        assert_equal 5, benchmark.fetch("values").size, "one benchmark point per trading day"
        assert_money_string "1005", benchmark.fetch("values").first["v"],
          "$1005 buys 10.05 SPY @ 100 -> 1005 on day one"

        meta = candles.fetch("meta")
        assert_equal false, meta["partial"]
        assert_equal [], meta["filled_dates"]

        # --- Sell pre-flight agrees with the position the candles imply ---
        get "/api/v1/portfolios/#{portfolio_id}/holdings",
          params: { instrument_id: instrument_id, as_of: FRI.iso8601 }
        assert_response :ok
        assert_money_string "20", json.dig("holding", "shares"), "pre-flight shares"

        # --- An oversell is rejected 422 naming the first offending date ---
        post "/api/v1/portfolios/#{portfolio_id}/transactions",
          params: { symbol: "AAPL", side: "sell", shares: 25, price: "105",
                    executed_on: FRI.iso8601 },
          headers: csrf_header, as: :json
        assert_response :unprocessable_entity
        details = assert_envelope("validation_failed")
        assert_match(/2026-07-10/, details.fetch("base").join, "the 422 names the offending date")

        # --- Summary agrees with the candles ---
        get "/api/v1/portfolios/#{portfolio_id}/summary"
        assert_response :ok
        summary = json.fetch("summary")
        assert_money_string "2100", summary["current_value"], "summary matches the FRI close"
        assert_money_string "2205", summary["net_deposits"], "1005 + 1200"
        assert_money_string "-105", summary["total_return"], "2100 - 2205"
        assert_in_delta(-105.0 / 2205, BigDecimal(summary["total_return_pct"]).to_f, 1e-6)
        assert_money_string "-0.25", summary["max_drawdown_pct"], "same all-time-peak drawdown as candles"
        assert_equal FRI.iso8601, summary["as_of"]

        # --- Allocations agree with the summary ---
        get "/api/v1/portfolios/#{portfolio_id}/allocations"
        assert_response :ok
        allocations = json.fetch("allocations")
        assert_equal summary["current_value"], allocations["total_value"],
          "allocations total must equal the summary's current value"
        slice = allocations.fetch("by_instrument").sole
        assert_equal "AAPL", slice["symbol"]
        assert_money_string "2100", slice["value"], "single holding carries the whole value"
        assert_money_string "1", slice["weight"], "weights sum to 1"

        # --- The ledger shows both buys, newest first ---
        get "/api/v1/portfolios/#{portfolio_id}/transactions"
        assert_response :ok
        assert_equal [ WED.iso8601, MON.iso8601 ],
          json.fetch("transactions").map { |t| t["executed_on"] }
        assert_equal 2, json.dig("meta", "total_count")

        # --- Logout revokes the session; the API is closed again ---
        delete "/api/v1/session", headers: csrf_header
        assert_response :no_content

        get "/api/v1/portfolios"
        assert_response :unauthorized
        assert_envelope "unauthenticated"
      end
    end
  end
end
