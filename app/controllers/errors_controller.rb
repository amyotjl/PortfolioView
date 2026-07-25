# Last-resort error renderer (docs/PLAN.md § API contract: "one error envelope
# everywhere"). Guarantees that failures under /api answer with the JSON
# envelope instead of Rails' static HTML error pages, via two entry points:
#
#   * #not_found — target of the /api/* catch-all route, for paths that match
#     no real route (routing 404s).
#   * #show      — target of config.exceptions_app, for anything that escapes a
#     controller: uncaught 500s, and any framework-level failure the middleware
#     stack turns into a status code.
#
# Inherits ActionController::Base directly (NOT ApplicationController): it must
# never require authentication, run CSRF verification, or the browser check —
# and it must never raise, since it is what runs when everything else has.
class ErrorsController < ActionController::Base
  include ErrorRendering

  # This renderer is read-only and mutates nothing, so CSRF adds no protection
  # here. The skip is also load-bearing: inheriting ActionController::Base brings
  # the framework-default forgery protection along, so without it a token-less
  # non-GET to the /api/* catch-all (#not_found) raises InvalidAuthenticityToken
  # and surfaces as 422 (HTML in dev) instead of the intended 404 envelope (#59).
  skip_forgery_protection

  # Stable, UTF-8 envelope codes per status. Built by hand rather than derived
  # from Rack::Utils::HTTP_STATUS_CODES via #parameterize: those reason strings
  # are ASCII-8BIT and transliteration raises on binary-encoded input.
  ERROR_CODES = {
    400 => "bad_request",
    401 => "unauthenticated",
    403 => "forbidden",
    404 => "not_found",
    406 => "not_acceptable",
    422 => "unprocessable_entity",
    429 => "rate_limited",
    500 => "internal_server_error"
  }.freeze

  # Catch-all route target: an unmatched /api/* path is always a 404.
  def not_found
    render_error(code: "not_found", message: "The requested resource was not found.", status: :not_found)
  end

  # config.exceptions_app target. Maps the stashed exception to a status and
  # renders the JSON envelope for /api requests; falls back to the static error
  # page for everything else (the future SPA owns its own non-API 404s).
  def show
    status = status_for(request.env["action_dispatch.exception"])

    if api_request?
      render_error(code: code_for(status), message: message_for(status), status: status)
    else
      render_static(status)
    end
  end

  private

  # ShowExceptions stashes the pre-rewrite path here before it sets PATH_INFO to
  # "/#{status}"; fall back to the current path if invoked some other way.
  def api_request?
    (request.env["action_dispatch.original_path"] || request.path).start_with?("/api")
  end

  def status_for(exception)
    return 500 unless exception

    ActionDispatch::ExceptionWrapper.new(nil, exception).status_code
  end

  def code_for(status)
    ERROR_CODES.fetch(status, "error")
  end

  def message_for(status)
    reason = Rack::Utils::HTTP_STATUS_CODES.fetch(status, "Error")
    "#{status} #{reason}.".encode("UTF-8")
  end

  # send_file streams the static page directly, bypassing ActionView rendering
  # (whose transliteration step rejects the binary-read file body).
  def render_static(status)
    page = Rails.public_path.join("#{status}.html")

    if page.file?
      send_file page, type: "text/html", disposition: "inline", status: status
    else
      render plain: message_for(status), status: status
    end
  end
end
