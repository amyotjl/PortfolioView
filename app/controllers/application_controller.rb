class ApplicationController < ActionController::Base
  include ErrorRendering
  include Authentication

  # Same-origin SPA auth (docs/PLAN.md § Architecture): HttpOnly session cookie +
  # CSRF token pair — XSRF-TOKEN cookie (readable by the SPA) echoed back in the
  # X-XSRF-TOKEN header. No CORS, no JWT.
  protect_from_forgery with: :exception

  rescue_from ActionController::InvalidAuthenticityToken do
    render_error code: "invalid_csrf_token", message: "CSRF token missing or invalid.", status: :forbidden
  end

  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  private

  # Accept the CSRF token from the X-XSRF-TOKEN header (set by the SPA from the
  # XSRF-TOKEN cookie) in addition to Rails' defaults.
  def request_authenticity_tokens
    super + [ request.headers["X-XSRF-TOKEN"] ].compact
  end
end
