require "test_helper"

module Api
  module V1
    class SessionsControllerTest < ActionDispatch::IntegrationTest
      setup do
        @user = users(:one)
      end

      # --- POST /api/v1/session (login) ---

      test "login with valid credentials returns the user and sets an HttpOnly session cookie" do
        post api_v1_session_path, params: login_params, as: :json

        assert_response :created
        body = JSON.parse(response.body)
        assert_equal @user.id, body.dig("user", "id")
        assert_equal "one@example.com", body.dig("user", "email_address")

        session_cookie = set_cookie_lines.grep(/\Asession_id=/).first
        assert session_cookie, "expected a session_id cookie to be set"
        assert_match(/httponly/i, session_cookie, "session cookie must be HttpOnly")
        assert_match(/samesite=lax/i, session_cookie, "session cookie must be same-site")
        assert_equal 1, @user.sessions.count, "login must create a DB-backed session row"
      end

      test "login with a case-variant email authenticates against the citext column" do
        post api_v1_session_path, params: { email_address: "ONE@EXAMPLE.COM", password: "password" }, as: :json

        assert_response :created
      end

      test "login with invalid credentials returns 401 with the error envelope" do
        post api_v1_session_path, params: { email_address: @user.email_address, password: "wrong" }, as: :json

        assert_response :unauthorized
        assert_error_envelope "invalid_credentials"
        assert_empty set_cookie_lines.grep(/\Asession_id=[^;]/), "no session cookie on failed login"
        assert_equal 0, Session.count
      end

      test "login with missing password returns 401 envelope instead of a server error" do
        post api_v1_session_path, params: { email_address: @user.email_address }, as: :json

        assert_response :unauthorized
        assert_error_envelope "invalid_credentials"
      end

      # --- Rate limiting (frozen contract: login is rate-limited) ---

      test "login is rate limited to 10 attempts per 3 minutes and answers 429 with the envelope" do
        10.times do
          post api_v1_session_path, params: { email_address: @user.email_address, password: "wrong" }, as: :json
          assert_response :unauthorized
        end

        post api_v1_session_path, params: login_params, as: :json

        assert_response :too_many_requests
        assert_error_envelope "rate_limited"
        assert_equal 0, Session.count, "rate-limited request must not log in"
      end

      # --- GET /api/v1/session (SPA bootstrap) ---

      test "bootstrap while signed out returns 401 envelope but still sets the CSRF cookie" do
        get api_v1_session_path

        assert_response :unauthorized
        assert_error_envelope "unauthenticated"
        assert cookies["XSRF-TOKEN"].present?, "bootstrap must set the XSRF-TOKEN cookie"
        xsrf_cookie = set_cookie_lines.grep(/\AXSRF-TOKEN=/).first
        assert_no_match(/httponly/i, xsrf_cookie, "CSRF cookie must be readable by the SPA")
      end

      test "bootstrap while signed in returns the current user and the CSRF cookie" do
        post api_v1_session_path, params: login_params, as: :json

        get api_v1_session_path

        assert_response :ok
        body = JSON.parse(response.body)
        assert_equal @user.id, body.dig("user", "id")
        assert cookies["XSRF-TOKEN"].present?
      end

      # --- DELETE /api/v1/session (logout) ---

      test "logout destroys the DB session row and signs the user out" do
        post api_v1_session_path, params: login_params, as: :json
        assert_equal 1, Session.count

        delete api_v1_session_path

        assert_response :no_content
        assert_equal 0, Session.count, "logout must revoke (destroy) the DB session row"

        get api_v1_session_path
        assert_response :unauthorized
      end

      test "logout without being signed in returns 401 envelope" do
        delete api_v1_session_path

        assert_response :unauthorized
        assert_error_envelope "unauthenticated"
      end

      # --- Revocation: destroying the session row invalidates the cookie ---

      test "destroying the session row server-side invalidates the cookie on the next request" do
        post api_v1_session_path, params: login_params, as: :json
        get api_v1_session_path
        assert_response :ok

        Session.find_by!(user: @user).destroy

        get api_v1_session_path
        assert_response :unauthorized
        assert_error_envelope "unauthenticated"
      end

      # --- CSRF: XSRF-TOKEN cookie <-> X-XSRF-TOKEN header pair ---

      test "state-changing request without a CSRF token is rejected with 403 envelope" do
        with_forgery_protection do
          post api_v1_session_path, params: login_params, as: :json

          assert_response :forbidden
          assert_error_envelope "invalid_csrf_token"
        end
      end

      test "login succeeds with the CSRF token from the bootstrap cookie echoed in X-XSRF-TOKEN" do
        with_forgery_protection do
          get api_v1_session_path # bootstrap: sets XSRF-TOKEN cookie

          post api_v1_session_path,
            params: login_params,
            headers: { "X-XSRF-TOKEN" => csrf_token_from_cookie },
            as: :json

          assert_response :created
        end
      end

      private

      def login_params
        { email_address: "one@example.com", password: "password" }
      end

      def assert_error_envelope(code)
        error = JSON.parse(response.body).fetch("error")
        assert_equal code, error.fetch("code")
        assert_kind_of String, error.fetch("message")
        assert error.key?("details"), "envelope must always carry details"
      end

      # Rack 3 may expose set-cookie as a String or an Array.
      def set_cookie_lines
        Array(response.headers["set-cookie"]).flat_map { |v| v.split("\n") }
      end

      def csrf_token_from_cookie
        raw = cookies["XSRF-TOKEN"]
        raw.include?("%") ? CGI.unescape(raw) : raw
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
