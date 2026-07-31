# Serves the Vue SPA shell (docs/PLAN.md § Architecture: "prod serves the Vite
# build from Rails public/ with an SPA catch-all route").
#
# The production image puts the Vite-built index.html at /rails/spa/index.html —
# outside public/ deliberately, so ActionDispatch::Static can't serve it for "/"
# with production.rb's far-future cache headers. Every request for the shell
# ("/" and any deep link such as /portfolios/1) therefore lands here and is
# answered no-store, while the hashed assets under public/assets keep the
# one-year max-age they deserve.
#
# Inherits ApplicationController on purpose: this is a browser HTML endpoint, so
# it keeps `allow_browser versions: :modern` and the standard CSRF configuration
# (a GET is never token-verified, so nothing is skipped and #59's contract is
# untouched). It only opts out of authentication — the shell must render for a
# signed-out visitor so the client router can send them to /login.
class SpaController < ApplicationController
  allow_unauthenticated_access

  def show
    path = spa_index_path

    # No build present (a dev checkout, or an image built without the frontend
    # stage): fall through to the ordinary 404 path rather than inventing a
    # response. Non-/api 404s keep their static HTML page, as before.
    raise ActionController::RoutingError, "No SPA build at #{path}" unless path && File.file?(path)

    # The shell names the current hashed asset filenames, so a cached copy
    # survives a rebuild and points at files that no longer exist.
    response.headers["Cache-Control"] = "no-store"

    # send_file streams the file directly and bypasses ActionView rendering,
    # matching how ErrorsController serves the static error pages.
    send_file path, type: "text/html", disposition: "inline"
  end

  private

  def spa_index_path
    Rails.configuration.x.spa_index_path
  end
end
