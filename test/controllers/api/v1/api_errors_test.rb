require "test_helper"

# backlog #025: "404 and 500 under /api also render the JSON envelope (never an
# HTML error page)." The 401 (unauthenticated) and 403 (CSRF) envelope paths are
# covered by the sessions/registrations controller tests; the not-found and
# uncaught-exception paths are the genuine delta this milestone adds and are
# proven here.
module Api
  module V1
    class ApiErrorsTest < ActionDispatch::IntegrationTest
      # --- Unmatched /api path -> 404 JSON envelope (the /api/* catch-all route) ---

      test "an unmatched /api path renders the 404 JSON envelope, not an HTML page" do
        get "/api/v1/does/not/exist"

        assert_response :not_found
        assert_equal "application/json", response.media_type
        assert_error_envelope "not_found"
      end

      test "an unmatched /api path answers the envelope for non-GET methods too" do
        post "/api/v1/nope", as: :json

        assert_response :not_found
        assert_equal "application/json", response.media_type
        assert_error_envelope "not_found"
      end

      # --- Uncaught exception under /api -> 500 JSON envelope (config.exceptions_app) ---

      test "an uncaught exception under /api renders the 500 JSON envelope, not an HTML page" do
        # Assertions stay inside with_routing: it resets the integration session
        # (nil-ing `response`) on exit.
        with_routing do |routes|
          routes.draw do
            get "/api/v1/__boom__", to: ->(_env) { raise "boom" }
          end

          with_framework_exception_rendering do
            get "/api/v1/__boom__"

            assert_response :internal_server_error
            assert_equal "application/json", response.media_type
            assert_error_envelope "internal_server_error"
          end
        end
      end

      private

      def assert_error_envelope(code)
        error = JSON.parse(response.body).fetch("error")
        assert_equal code, error.fetch("code")
        assert_kind_of String, error.fetch("message")
        assert error.key?("details"), "envelope must always carry details"
      end

      # Force the exception-handling middleware into its production posture so
      # config.exceptions_app is actually invoked: with detailed exceptions on
      # (the test default) DebugExceptions renders its own HTML debug page and
      # exceptions_app never runs. Toggled on Rails.application.env_config, which
      # is merged into every request's env, then restored.
      def with_framework_exception_rendering
        env = Rails.application.env_config
        saved = env.slice("action_dispatch.show_exceptions", "action_dispatch.show_detailed_exceptions")
        env["action_dispatch.show_exceptions"] = :all
        env["action_dispatch.show_detailed_exceptions"] = false
        yield
      ensure
        env.merge!(saved)
      end
    end
  end
end
