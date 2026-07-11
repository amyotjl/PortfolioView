require "test_helper"

module Api
  module V1
    class RegistrationsControllerTest < ActionDispatch::IntegrationTest
      VALID_INVITE_CODE = "test-invite-code".freeze

      setup do
        @original_invite_code = ENV["INVITE_CODE"]
        ENV["INVITE_CODE"] = VALID_INVITE_CODE
      end

      teardown do
        ENV["INVITE_CODE"] = @original_invite_code
      end

      # --- Successful registration ---

      test "registration with a matching invite code creates the user and returns 201" do
        assert_difference "User.count", 1 do
          post api_v1_registration_path, params: registration_params, as: :json
        end

        assert_response :created
        body = JSON.parse(response.body)
        assert_equal "new@example.com", body.dig("user", "email_address")
        assert body.dig("user", "id").present?
        assert User.find_by(email_address: "new@example.com").authenticate("password123"),
          "stored password must authenticate"
      end

      test "successful registration signs the user in with an HttpOnly session cookie" do
        post api_v1_registration_path, params: registration_params, as: :json
        assert_response :created

        user = User.find_by!(email_address: "new@example.com")
        assert_equal 1, user.sessions.count, "registration must create a DB-backed session row"

        session_cookie = set_cookie_lines.grep(/\Asession_id=/).first
        assert session_cookie, "expected a session_id cookie to be set"
        assert_match(/httponly/i, session_cookie, "session cookie must be HttpOnly")
        assert_match(/samesite=lax/i, session_cookie, "session cookie must be same-site")

        # The SPA must be able to proceed without a second login.
        get api_v1_session_path
        assert_response :ok
        assert_equal user.id, JSON.parse(response.body).dig("user", "id")
      end

      test "registration normalizes the email address" do
        post api_v1_registration_path,
          params: registration_params(email_address: "  MixedCase@Example.COM "), as: :json

        assert_response :created
        assert_equal "mixedcase@example.com",
          JSON.parse(response.body).dig("user", "email_address")
      end

      # --- Invite gating ---

      test "wrong invite code returns 422 envelope mapped onto the invite_code field and creates nothing" do
        assert_no_difference [ "User.count", "Session.count" ] do
          post api_v1_registration_path,
            params: registration_params(invite_code: "wrong-code"), as: :json
        end

        assert_response :unprocessable_entity
        details = assert_error_envelope("invalid_invite_code")
        assert details.key?("invite_code"), "422 details must map onto the invite_code field"
        assert_empty set_cookie_lines.grep(/\Asession_id=[^;]/), "no session cookie on rejected registration"
      end

      test "missing invite code returns 422 envelope and creates nothing" do
        assert_no_difference [ "User.count", "Session.count" ] do
          post api_v1_registration_path,
            params: registration_params.except(:invite_code), as: :json
        end

        assert_response :unprocessable_entity
        assert_error_envelope "invalid_invite_code"
      end

      test "registration is closed (never fails open) when INVITE_CODE env is unset" do
        ENV["INVITE_CODE"] = nil

        assert_no_difference "User.count" do
          post api_v1_registration_path, params: registration_params(invite_code: ""), as: :json
        end

        assert_response :unprocessable_entity
        assert_error_envelope "invalid_invite_code"
      end

      test "registration is closed when INVITE_CODE env is blank" do
        ENV["INVITE_CODE"] = ""

        assert_no_difference "User.count" do
          post api_v1_registration_path, params: registration_params(invite_code: ""), as: :json
        end

        assert_response :unprocessable_entity
        assert_error_envelope "invalid_invite_code"
      end

      # --- Validation failures (422 details map onto form fields) ---

      test "duplicate email returns 422 with details mapped onto the email_address field" do
        assert_no_difference [ "User.count", "Session.count" ] do
          post api_v1_registration_path,
            params: registration_params(email_address: users(:one).email_address), as: :json
        end

        assert_response :unprocessable_entity
        details = assert_error_envelope("validation_failed")
        assert details.key?("email_address"), "duplicate email must map onto the email_address field"
      end

      test "duplicate email is rejected case-insensitively (citext column)" do
        assert_no_difference "User.count" do
          post api_v1_registration_path,
            params: registration_params(email_address: "ONE@EXAMPLE.COM"), as: :json
        end

        assert_response :unprocessable_entity
        details = assert_error_envelope("validation_failed")
        assert details.key?("email_address")
      end

      test "missing email returns 422 with details mapped onto the email_address field" do
        assert_no_difference "User.count" do
          post api_v1_registration_path,
            params: registration_params.except(:email_address), as: :json
        end

        assert_response :unprocessable_entity
        details = assert_error_envelope("validation_failed")
        assert details.key?("email_address")
      end

      test "missing password returns 422 with details mapped onto the password field" do
        assert_no_difference "User.count" do
          post api_v1_registration_path,
            params: registration_params.except(:password), as: :json
        end

        assert_response :unprocessable_entity
        details = assert_error_envelope("validation_failed")
        assert details.key?("password")
      end

      test "password confirmation mismatch returns 422 mapped onto the password_confirmation field" do
        assert_no_difference "User.count" do
          post api_v1_registration_path,
            params: registration_params(password_confirmation: "different"), as: :json
        end

        assert_response :unprocessable_entity
        details = assert_error_envelope("validation_failed")
        assert details.key?("password_confirmation")
      end

      # --- Rate limiting (defense against invite-code brute force) ---

      test "registration is rate limited to 10 attempts per 3 minutes and answers 429 with the envelope" do
        10.times do
          post api_v1_registration_path,
            params: registration_params(invite_code: "wrong-code"), as: :json
          assert_response :unprocessable_entity
        end

        assert_no_difference "User.count" do
          post api_v1_registration_path, params: registration_params, as: :json
        end

        assert_response :too_many_requests
        assert_error_envelope "rate_limited"
      end

      private

      def registration_params(overrides = {})
        {
          email_address: "new@example.com",
          password: "password123",
          password_confirmation: "password123",
          invite_code: VALID_INVITE_CODE
        }.merge(overrides)
      end

      # Asserts the frozen envelope shape and returns details for field checks.
      def assert_error_envelope(code)
        error = JSON.parse(response.body).fetch("error")
        assert_equal code, error.fetch("code")
        assert_kind_of String, error.fetch("message")
        assert error.key?("details"), "envelope must always carry details"
        error.fetch("details")
      end

      # Rack 3 may expose set-cookie as a String or an Array.
      def set_cookie_lines
        Array(response.headers["set-cookie"]).flat_map { |v| v.split("\n") }
      end
    end
  end
end
