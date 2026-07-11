module Api
  module V1
    # Invite-gated signup (docs/PLAN.md § API contract): POST /api/v1/registration
    # requires the submitted invite code to match the INVITE_CODE env value.
    # Deliberately hand-rolled (no Devise) per the plan's stack decision.
    class RegistrationsController < BaseController
      allow_unauthenticated_access only: :create

      # Not in the frozen contract, but an unthrottled endpoint would let the
      # invite code be brute-forced; mirrors the login limiter.
      rate_limit to: 10, within: 3.minutes, only: :create, with: -> {
        render_error code: "rate_limited", message: "Too many registration attempts. Try again later.", status: :too_many_requests
      }

      # POST /api/v1/registration
      def create
        unless valid_invite_code?
          return render_error(
            code: "invalid_invite_code",
            message: "Invite code is missing or invalid.",
            status: :unprocessable_entity,
            details: { invite_code: [ "is missing or invalid" ] }
          )
        end

        user = User.new(user_params)

        if user.save
          # Sign the new user in immediately so the SPA can proceed without a
          # second login (same DB-backed session + HttpOnly cookie as login).
          start_new_session_for(user)
          render json: { user: UserSerializer.new(user).as_json }, status: :created
        else
          render_error(
            code: "validation_failed",
            message: "Registration failed validation.",
            status: :unprocessable_entity,
            details: user.errors.as_json
          )
        end
      end

      private

      def user_params
        params.permit(:email_address, :password, :password_confirmation)
      end

      # Registration is CLOSED when INVITE_CODE is unset/blank — a missing env
      # var must never fail open. Constant-time comparison so the code can't be
      # guessed via response timing.
      def valid_invite_code?
        configured = ENV["INVITE_CODE"]
        submitted = params[:invite_code]

        configured.present? && submitted.present? &&
          ActiveSupport::SecurityUtils.secure_compare(configured, submitted.to_s)
      end
    end
  end
end
