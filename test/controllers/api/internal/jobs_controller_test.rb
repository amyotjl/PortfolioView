require "test_helper"

module Api
  module Internal
    # issue #56: POST /api/internal/jobs/daily_sync — bearer-token guarded,
    # session-less and CSRF-less by design.
    class JobsControllerTest < ActionDispatch::IntegrationTest
      include ActiveJob::TestHelper

      PATH = "/api/internal/jobs/daily_sync".freeze
      TOKEN = "s3cr3t-internal-token-for-tests".freeze

      # The 401 body, verbatim. Asserted byte-for-byte (not key-by-key) so a
      # refactor that reshapes the envelope for this route has to come here and
      # say so out loud (docs/API_SHAPES.md § error envelope).
      UNAUTHORIZED_BODY =
        %({"error":{"code":"unauthenticated","message":"A valid internal API token is required.","details":{}}}).freeze

      setup do
        @original_token = ENV["INTERNAL_API_TOKEN"]
        ENV["INTERNAL_API_TOKEN"] = TOKEN
      end

      teardown do
        ENV["INTERNAL_API_TOKEN"] = @original_token
      end

      # -- happy path ---------------------------------------------------------

      test "a valid bearer token enqueues Prices::DailySyncJob and answers 202" do
        assert_enqueued_with(job: Prices::DailySyncJob) do
          post PATH, headers: bearer(TOKEN)
        end

        assert_response :accepted
        assert_equal "application/json", response.media_type
        assert_equal %w[sync], json.keys
        assert_equal %w[requested_at status], json["sync"].keys.sort
        assert_equal "enqueued", json.dig("sync", "status")
        assert_nothing_raised { Time.iso8601(json.dig("sync", "requested_at")) }
        assert_match(/Z\z/, json.dig("sync", "requested_at"), "requested_at is ISO-8601 UTC")
      end

      test "the route needs NEITHER a session NOR a CSRF token, with forgery protection ON" do
        with_forgery_protection do
          assert_enqueued_with(job: Prices::DailySyncJob) do
            post PATH, headers: bearer(TOKEN)
          end

          assert_response :accepted, "a cron caller has no cookie jar and no CSRF token"
        end

        assert_nil cookies["session_id"].presence, "the internal route must not start a session"
      end

      test "a browser-less caller is not blocked by the modern-browser gate" do
        post PATH, headers: bearer(TOKEN).merge("User-Agent" => "curl/8.5.0")

        assert_response :accepted
      end

      # -- bad token ----------------------------------------------------------

      test "a missing Authorization header is 401 in the standard envelope and enqueues nothing" do
        assert_no_enqueued_jobs do
          post PATH
        end

        assert_unauthorized
      end

      test "a wrong bearer token is 401 and enqueues nothing" do
        assert_no_enqueued_jobs do
          post PATH, headers: bearer("definitely-not-the-token")
        end

        assert_unauthorized
      end

      test "a token that is a prefix or a superstring of the real one is rejected" do
        [ TOKEN[0..-2], "#{TOKEN}x", TOKEN.upcase, TOKEN.reverse ].each do |candidate|
          assert_no_enqueued_jobs { post PATH, headers: bearer(candidate) }
          assert_unauthorized
        end
      end

      # RFC 9110's `credentials = auth-scheme 1*SP token68` allows more than one
      # space, and a shell that interpolates an empty var into the header is a
      # far more likely cause of stray whitespace than an attack. Tolerated.
      test "extra whitespace around the credential is tolerated" do
        [ "Bearer  #{TOKEN}", "Bearer #{TOKEN} ", "bearer #{TOKEN}" ].each do |authorization|
          Rails.cache.delete(Prices::SyncTrigger::CLAIM_KEY)

          assert_enqueued_with(job: Prices::DailySyncJob) do
            post PATH, headers: { "Authorization" => authorization }
          end
          assert_response :accepted
        end
      end

      test "a non-Bearer scheme carrying the right secret is rejected" do
        [ "Basic #{TOKEN}", %(Token token="#{TOKEN}"), TOKEN ].each do |authorization|
          assert_no_enqueued_jobs { post PATH, headers: { "Authorization" => authorization } }
          assert_unauthorized
        end
      end

      test "an empty bearer value is rejected" do
        [ "Bearer", "Bearer ", "Bearer    " ].each do |authorization|
          assert_no_enqueued_jobs { post PATH, headers: { "Authorization" => authorization } }
          assert_unauthorized
        end
      end

      test "an unset or blank INTERNAL_API_TOKEN fails CLOSED — nothing authenticates" do
        [ nil, "", "   " ].each do |configured|
          ENV["INTERNAL_API_TOKEN"] = configured

          [ {}, bearer(""), bearer(TOKEN), bearer("anything") ].each do |headers|
            assert_no_enqueued_jobs { post PATH, headers: headers }
            assert_unauthorized
          end
        end
      end

      test "a signed-in session buys nothing here — the token is the only credential" do
        sign_in_as users(:one)

        assert_no_enqueued_jobs { post PATH }

        assert_unauthorized
      end

      test "the 401 carries a WWW-Authenticate challenge without disturbing the envelope" do
        post PATH

        assert_equal 'Bearer realm="portfolioview-internal"', response.headers["WWW-Authenticate"]
        assert_unauthorized
      end

      # -- double trigger -----------------------------------------------------

      test "re-triggering while a sync is pending answers 202 already_pending and enqueues NO second job" do
        post PATH, headers: bearer(TOKEN)
        assert_response :accepted
        assert_equal "enqueued", json.dig("sync", "status")
        first_requested_at = json.dig("sync", "requested_at")

        assert_no_enqueued_jobs(only: Prices::DailySyncJob) do
          post PATH, headers: bearer(TOKEN)
        end

        assert_response :accepted
        assert_equal "already_pending", json.dig("sync", "status")
        assert_equal first_requested_at, json.dig("sync", "requested_at"),
          "the no-op echoes the PENDING sync's claim time, not this request's"
        assert_enqueued_jobs 1, only: Prices::DailySyncJob
      end

      test "the internal route and the SPA route share one dedupe lease" do
        post PATH, headers: bearer(TOKEN)
        assert_equal "enqueued", json.dig("sync", "status")

        sign_in_as users(:one)
        assert_no_enqueued_jobs(only: Prices::DailySyncJob) do
          post "/api/v1/sync", as: :json
        end

        assert_response :accepted
        assert_equal "already_pending", json.dig("sync", "status")
        assert_enqueued_jobs 1, only: Prices::DailySyncJob
      end

      # -- routing ------------------------------------------------------------

      test "only POST is routed; other verbs fall through to the /api/* 404 envelope" do
        %i[get patch delete].each do |verb|
          send(verb, PATH)
          assert_response :not_found
          assert_equal "not_found", json.dig("error", "code")
        end
      end

      private

      def bearer(token) = { "Authorization" => "Bearer #{token}" }

      def json = JSON.parse(response.body)

      def assert_unauthorized
        assert_response :unauthorized
        assert_equal "application/json", response.media_type
        assert_equal UNAUTHORIZED_BODY, response.body,
          "the 401 must be the standard envelope, byte for byte"
      end

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
