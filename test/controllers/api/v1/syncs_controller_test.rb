require "test_helper"

module Api
  module V1
    # issue #56 (consumed by #57): POST /api/v1/sync — the SPA's supported
    # "Sync now" path. Session + CSRF, never a bearer token.
    class SyncsControllerTest < ActionDispatch::IntegrationTest
      include ActiveJob::TestHelper
      include DomainTestHelper

      PATH = "/api/v1/sync".freeze

      setup do
        # 10:00 ET on a Wednesday. Frozen because the freshness predicate has a
        # 22:00 ET cutoff (issue #59): without this, every seed-relative
        # assertion below would flip meaning if the suite happened to run in the
        # evening.
        travel_to Time.utc(2026, 7, 22, 14, 0)
        @user = users(:one)
      end

      # ---------------------------------------------------------------------
      # GET /api/v1/sync — the freshness snapshot #57's Settings page renders.
      # ---------------------------------------------------------------------

      test "GET returns the frozen key set, with nulls on a fresh database" do
        sign_in_as @user

        get PATH

        assert_response :ok
        assert_equal %w[sync], json.keys
        assert_equal %w[instruments_behind last_trading_day latest_price_on pending requested_at stale],
          json["sync"].keys.sort, "exact frozen key set — the zod schema mirrors this"

        snapshot = json["sync"]
        assert_nil snapshot["latest_price_on"], "no instruments cached in a fresh database"
        assert_nil snapshot["last_trading_day"]
        assert_nil snapshot["requested_at"]
        assert_equal true, snapshot["stale"], "nothing cached => a sync is needed"
        assert_equal false, snapshot["pending"]
        assert_equal 0, snapshot["instruments_behind"], "an integer, never null, even on an empty database"
      end

      # issue #59: the signal `stale` structurally cannot give. SPY is always
      # referenced, so it holds the MAX up and one failed single-symbol fetch is
      # invisible to `stale`.
      test "GET reports a single lagging instrument that stale alone cannot see" do
        seed_current_calendar
        aapl = create_instrument(symbol: "AAPL")
        Benchmark.create!(instrument: aapl, name: "AAPL bench")
        aapl.update!(latest_price_on: @last_trading_day - 4)
        sign_in_as @user

        get PATH

        assert_response :ok
        assert_equal false, json.dig("sync", "stale"), "the cache as a whole is current"
        assert_equal 1, json.dig("sync", "instruments_behind"), "one symbol is not"
        assert_equal @last_trading_day.iso8601, json.dig("sync", "latest_price_on"),
          "the display value stays the MAX — #57 renders 'prices current through'"
      end

      test "GET reports ISO dates and stale=false once the cache is current" do
        seed_current_calendar
        sign_in_as @user

        get PATH

        assert_response :ok
        assert_equal @last_trading_day.iso8601, json.dig("sync", "latest_price_on")
        assert_equal @last_trading_day.iso8601, json.dig("sync", "last_trading_day")
        assert_equal false, json.dig("sync", "stale")
        assert_match(/\A\d{4}-\d{2}-\d{2}\z/, json.dig("sync", "latest_price_on"),
          "dates are bare ISO YYYY-MM-DD, never timestamps")
      end

      test "GET reports stale=true when the cache has fallen behind" do
        seed_stale_calendar
        sign_in_as @user

        get PATH

        assert_response :ok
        assert_equal true, json.dig("sync", "stale")
        assert_equal @last_trading_day.iso8601, json.dig("sync", "last_trading_day"),
          "a stale snapshot still reports the date it IS current through"
      end

      test "GET surfaces an in-flight sync, so the page can render pending state on load" do
        sign_in_as @user

        post PATH, as: :json
        assert_equal "enqueued", json.dig("sync", "status")
        requested_at = json.dig("sync", "requested_at")

        get PATH

        assert_response :ok
        assert_equal true, json.dig("sync", "pending")
        assert_equal requested_at, json.dig("sync", "requested_at"),
          "GET's requested_at is the same claim time POST returned"
      end

      test "GET never requires a CSRF token" do
        sign_in_as @user

        with_forgery_protection do
          get PATH
          assert_response :ok
        end
      end

      test "GET is auth-gated with the 401 envelope" do
        get PATH

        assert_response :unauthorized
        assert_equal %w[code details message], json.fetch("error").keys.sort
        assert_equal "unauthenticated", json.dig("error", "code")
      end

      test "GET never enqueues anything — reading freshness is not triggering a sync" do
        sign_in_as @user

        assert_no_enqueued_jobs(only: Prices::DailySyncJob) { get PATH }

        assert_response :ok
      end

      # ---------------------------------------------------------------------
      # POST /api/v1/sync
      # ---------------------------------------------------------------------

      test "a signed-in user enqueues Prices::DailySyncJob and gets 202" do
        sign_in_as @user

        assert_enqueued_with(job: Prices::DailySyncJob) do
          post PATH, as: :json
        end

        assert_response :accepted
        assert_equal %w[sync], json.keys
        assert_equal %w[requested_at status], json["sync"].keys.sort
        assert_equal "enqueued", json.dig("sync", "status")
        assert_match(/Z\z/, json.dig("sync", "requested_at"))
      end

      test "the body is byte-identical in shape to the internal route's" do
        original = ENV["INTERNAL_API_TOKEN"]
        ENV["INTERNAL_API_TOKEN"] = "token-for-this-test"

        post "/api/internal/jobs/daily_sync", headers: { "Authorization" => "Bearer token-for-this-test" }
        internal_keys = json["sync"].keys.sort
        Rails.cache.delete(Prices::SyncTrigger::CLAIM_KEY)

        sign_in_as @user
        post PATH, as: :json

        assert_equal internal_keys, json["sync"].keys.sort,
          "both doors onto the same job must answer the same shape (the UI must not care which)"
      ensure
        ENV["INTERNAL_API_TOKEN"] = original
      end

      test "an anonymous caller gets the 401 unauthenticated envelope and enqueues nothing" do
        assert_no_enqueued_jobs { post PATH, as: :json }

        assert_response :unauthorized
        assert_equal "application/json", response.media_type
        assert_equal %w[code details message], json.fetch("error").keys.sort
        assert_equal "unauthenticated", json.dig("error", "code")
      end

      test "the bearer token does NOT authorize this route — it is session-only" do
        original = ENV["INTERNAL_API_TOKEN"]
        ENV["INTERNAL_API_TOKEN"] = "a-real-internal-token"

        assert_no_enqueued_jobs do
          post PATH, headers: { "Authorization" => "Bearer a-real-internal-token" }, as: :json
        end

        assert_response :unauthorized
        assert_equal "unauthenticated", json.dig("error", "code")
      ensure
        ENV["INTERNAL_API_TOKEN"] = original
      end

      test "a token-less POST is rejected 403 invalid_csrf_token with no job enqueued" do
        sign_in_as @user

        with_forgery_protection do
          assert_no_enqueued_jobs { post PATH, as: :json }

          assert_response :forbidden
          assert_equal "invalid_csrf_token", json.dig("error", "code")
        end
      end

      test "echoing the XSRF-TOKEN cookie authorizes the trigger" do
        sign_in_as @user

        with_forgery_protection do
          get "/api/v1/session" # refreshes the readable CSRF cookie

          assert_enqueued_with(job: Prices::DailySyncJob) do
            post PATH, headers: csrf_header, as: :json
          end

          assert_response :accepted
        end
      end

      test "double-clicking Sync now enqueues exactly one job" do
        sign_in_as @user

        post PATH, as: :json
        assert_response :accepted
        assert_equal "enqueued", json.dig("sync", "status")
        first_requested_at = json.dig("sync", "requested_at")

        assert_no_enqueued_jobs(only: Prices::DailySyncJob) do
          3.times { post PATH, as: :json }
        end

        assert_response :accepted
        assert_equal "already_pending", json.dig("sync", "status")
        assert_equal first_requested_at, json.dig("sync", "requested_at")
        assert_enqueued_jobs 1, only: Prices::DailySyncJob
      end

      private

      # A calendar whose newest day IS Prices::Freshness's expected session.
      # Time is frozen at 10:00 ET in setup, i.e. before the 22:00 data drop, so
      # that is the most recent weekday before today and the snapshot reads
      # current.
      def seed_current_calendar
        @last_trading_day = previous_weekday(Trading::Calendar.today)
        seed_calendar_through(@last_trading_day)
      end

      # 14 days, not 10: create_trading_days only seeds weekdays, so a target
      # that lands on a weekend would leave the calendar's real newest day two
      # days earlier than @last_trading_day. A whole number of weeks preserves
      # the weekday whatever `today` is.
      def seed_stale_calendar
        @last_trading_day = previous_weekday(Trading::Calendar.today) - 14.days
        seed_calendar_through(@last_trading_day)
      end

      def seed_calendar_through(date)
        spy = create_trading_days(date - 20.days, date)
        spy.update!(latest_price_on: date)
        Benchmark.create!(instrument: spy, name: "S&P 500 test")
      end

      def previous_weekday(from)
        date = from - 1
        date -= 1 while date.saturday? || date.sunday?
        date
      end

      def json = JSON.parse(response.body)

      def csrf_token_from_cookie
        raw = cookies["XSRF-TOKEN"]
        raw.include?("%") ? CGI.unescape(raw) : raw
      end

      def csrf_header = { "X-XSRF-TOKEN" => csrf_token_from_cookie }

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
