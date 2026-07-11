module Api
  module V1
    class SessionsController < BaseController
      allow_unauthenticated_access only: %i[ show create ]
      rate_limit to: 10, within: 3.minutes, only: :create, with: -> {
        render_error code: "rate_limited", message: "Too many login attempts. Try again later.", status: :too_many_requests
      }

      # GET /api/v1/session — SPA bootstrap: current user + CSRF cookie (set by after_action).
      def show
        if authenticated?
          render json: { user: UserSerializer.new(Current.user).as_json }
        else
          render_error code: "unauthenticated", message: "You must be signed in.", status: :unauthorized
        end
      end

      # POST /api/v1/session — login.
      def create
        credentials = params.permit(:email_address, :password)

        if credentials[:email_address].present? && credentials[:password].present? &&
           (user = User.authenticate_by(credentials))
          start_new_session_for(user)
          render json: { user: UserSerializer.new(user).as_json }, status: :created
        else
          render_error code: "invalid_credentials", message: "Invalid email address or password.", status: :unauthorized
        end
      end

      # DELETE /api/v1/session — logout: revokes the DB session row.
      def destroy
        terminate_session
        head :no_content
      end
    end
  end
end
