require "test_helper"

module Api
  module V1
    # issue #56 (consumed by #57): POST /api/v1/sync — the SPA's supported
    # "Sync now" path. Session + CSRF, never a bearer token.
    class SyncsControllerTest < ActionDispatch::IntegrationTest
      include ActiveJob::TestHelper

      PATH = "/api/v1/sync".freeze

      setup { @user = users(:one) }

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
