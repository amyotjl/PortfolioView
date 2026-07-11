module Api
  module V1
    class BaseController < ApplicationController
      # Every API response refreshes the CSRF cookie, so the SPA always has a
      # token to echo back in X-XSRF-TOKEN. Deliberately NOT HttpOnly — the SPA
      # must read it; the session cookie remains HttpOnly.
      after_action :set_csrf_cookie

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
