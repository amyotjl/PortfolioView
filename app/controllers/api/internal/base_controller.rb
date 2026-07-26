module Api
  # Machine-to-machine surface (docs/PLAN.md § Deployment). NOT part of the
  # browser SPA's API: there is no session, no CSRF pair and no user here — a
  # cron job, a systemd timer or a `curl` from the host is the intended caller.
  module Internal
    # Inherits ActionController::Base DIRECTLY, not ApplicationController —
    # the same deliberate choice ErrorsController makes, and for overlapping
    # reasons. Via ApplicationController this route would pick up three things
    # that are all wrong for a machine caller:
    #
    #   * `Authentication` (`before_action :require_authentication`) — the
    #     bearer token IS the credential; there is no session cookie to resume.
    #   * the CSRF token pair — CSRF defends cookie-borne ambient authority. A
    #     bearer token is not ambient (a cross-site form post cannot attach an
    #     Authorization header), so there is nothing to forge, and requiring a
    #     token would make the endpoint uncallable by cron.
    #   * `allow_browser versions: :modern` — a UA-sniffing gate that answers
    #     406 to `curl`, which has no browser UA at all.
    #
    # Opting out narrowly here keeps ApplicationController's app-wide defaults
    # untouched: every /api/v1 route still requires a session AND the CSRF pair.
    class BaseController < ActionController::Base
      include ErrorRendering

      # Load-bearing, exactly as on ErrorsController (#59): inheriting
      # ActionController::Base brings Rails' default `protect_from_forgery`
      # along, so without this skip a token-holding cron POST raises
      # InvalidAuthenticityToken and surfaces as 422 instead of running.
      skip_forgery_protection

      before_action :authenticate_internal_token!

      # The env var guarding every /api/internal route. Blank or unset => the
      # whole namespace is CLOSED (see #valid_internal_token?).
      TOKEN_ENV = "INTERNAL_API_TOKEN".freeze

      private

      def authenticate_internal_token!
        return if valid_internal_token?

        # Correct HTTP for a bearer-guarded resource; the BODY is the standard
        # error envelope, unchanged (docs/API_SHAPES.md).
        response.set_header("WWW-Authenticate", 'Bearer realm="portfolioview-internal"')
        render_error(
          code: "unauthenticated",
          message: "A valid internal API token is required.",
          status: :unauthorized
        )
      end

      # FAILS CLOSED: an unset or blank INTERNAL_API_TOKEN authenticates nobody,
      # so a deploy that forgets the var is inert rather than wide open (same
      # rule as INVITE_CODE in RegistrationsController). Constant-time compare
      # so the token can't be recovered byte-by-byte from response timing;
      # `secure_compare` digests first, so unequal lengths are safe too.
      def valid_internal_token?
        configured = ENV[TOKEN_ENV]
        presented = bearer_token

        configured.present? && presented.present? &&
          ActiveSupport::SecurityUtils.secure_compare(configured, presented)
      end

      # Only the `Bearer` scheme is accepted. A bare token, `Basic`, or Rails'
      # own `Token token="..."` form is not a bearer credential and is rejected
      # rather than quietly coerced.
      def bearer_token
        scheme, value = request.authorization.to_s.split(" ", 2)
        return nil unless scheme.to_s.casecmp("bearer").zero?

        value.to_s.strip.presence
      end
    end
  end
end
