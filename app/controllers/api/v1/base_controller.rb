module Api
  module V1
    class BaseController < ApplicationController
      # Every API response refreshes the CSRF cookie, so the SPA always has a
      # token to echo back in X-XSRF-TOKEN. Deliberately NOT HttpOnly — the SPA
      # must read it; the session cookie remains HttpOnly.
      after_action :set_csrf_cookie

      # A record scoped to Current.user (e.g. `Current.user.portfolios.find`)
      # raises RecordNotFound both when the id is unknown and when it belongs to
      # another user — either way, a uniform 404 envelope (never HTML, never 403).
      rescue_from ActiveRecord::RecordNotFound do
        render_not_found
      end

      private

      def set_csrf_cookie
        cookies["XSRF-TOKEN"] = {
          value: form_authenticity_token,
          httponly: false,
          same_site: :lax,
          secure: request.ssl?
        }
      end
    end
  end
end
