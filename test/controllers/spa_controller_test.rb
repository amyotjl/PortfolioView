require "test_helper"

# backlog #054: "The SPA is served by Rails with a catch-all route: a deep link
# such as /portfolios/1 loads the app".
#
# The real shell only exists inside the production image (the Dockerfile writes
# the Vite build to /rails/spa/index.html), so these tests point
# config.x.spa_index_path at a fixture standing in for it. What they lock down is
# the *routing and response* contract around it — including the two things the
# catch-all could plausibly break: the /api/* JSON-404 envelope (#59) and the
# static HTML 404 for unmatched non-/api paths when no build is present.
class SpaControllerTest < ActionDispatch::IntegrationTest
  SHELL_MARKER = '<div id="app"></div>'.freeze

  # --- With a build present: the shell answers "/" and every deep link --------

  test "the root path serves the SPA shell" do
    with_spa_build do
      get "/"

      assert_response :success
      assert_equal "text/html", response.media_type
      assert_includes response.body, SHELL_MARKER
    end
  end

  test "a deep link into the client router serves the SPA shell, not a 404" do
    with_spa_build do
      %w[/portfolios /portfolios/1 /portfolios/1/transactions /portfolios/1/recurring /settings /login].each do |path|
        get path

        assert_response :success, "#{path} must load the SPA shell"
        assert_equal "text/html", response.media_type, "#{path} must be HTML"
        assert_includes response.body, SHELL_MARKER, "#{path} must be the SPA shell"
      end
    end
  end

  test "the shell renders for a signed-out visitor so the client router can redirect to /login" do
    with_spa_build do
      get "/portfolios/1"

      assert_response :success
      assert_no_match(/"error"\s*:/, response.body, "the shell must not be an auth error envelope")
    end
  end

  test "the shell is served no-store so a rebuilt image is not shadowed by a cached copy" do
    with_spa_build do
      get "/"

      assert_equal "no-store", response.headers["Cache-Control"],
                   "index.html names hashed asset filenames and must never be cached"
    end
  end

  test "an unknown deep path with a dot in it still serves the shell" do
    with_spa_build do
      get "/portfolios/1.5"

      assert_response :success
      assert_includes response.body, SHELL_MARKER
    end
  end

  # --- The catch-all must not swallow the API or the health check ------------

  test "the catch-all does not swallow unmatched /api paths: still the JSON 404 envelope" do
    with_spa_build do
      get "/api/v1/does/not/exist"

      assert_response :not_found
      assert_equal "application/json", response.media_type
      assert_equal "not_found", JSON.parse(response.body).dig("error", "code")
    end
  end

  test "the catch-all does not swallow token-less non-GETs to unmatched /api paths (#59)" do
    with_spa_build do
      with_forgery_protection do
        %i[post patch delete].each do |verb|
          send(verb, "/api/v1/does-not-exist", as: :json)

          assert_response :not_found, "#{verb.upcase} to an unmatched /api path must stay the 404 envelope"
          assert_equal "application/json", response.media_type
          assert_equal "not_found", JSON.parse(response.body).dig("error", "code")
        end
      end
    end
  end

  # The routes constraint is `!request.path.start_with?("/api", "/rails/")`.
  # Its "/api" half is belt-and-braces — the /api/* JSON-404 catch-all is
  # declared ABOVE the glob and matches first — so removing the whole lambda
  # broke no test, which #54's gate flagged as vacuous coverage.
  #
  # "/rails/" has no such earlier guard. Without the constraint the glob
  # swallows framework-reserved paths (Active Storage, Action Mailbox, the
  # health mount) and answers 200 with the SPA shell instead of letting Rails
  # 404 them — so an engine mounted there later would silently never be
  # reachable. This is the assertion that actually holds the lambda in place.
  test "the catch-all does not swallow framework-reserved /rails/ paths" do
    with_spa_build do
      with_framework_exception_rendering do
        get "/rails/active_storage/blobs/nonexistent"

        assert_response :not_found
        assert_not_includes response.body, SHELL_MARKER,
          "the SPA glob must not answer /rails/* — the routes constraint exists for this"
      end
    end
  end

  test "the health check still answers itself, not the SPA shell" do
    with_spa_build do
      get "/up"

      assert_response :success
      assert_not_includes response.body, SHELL_MARKER
    end
  end

  test "an unknown non-GET, non-/api request is not routed to the SPA" do
    with_spa_build do
      with_framework_exception_rendering do
        post "/definitely-not-a-real-page"

        assert_response :not_found
        assert_not_includes response.body, SHELL_MARKER
      end
    end
  end

  # --- Without a build (a dev checkout): the ordinary 404 path ---------------

  test "with no SPA build present, an unmatched path falls back to the static HTML 404" do
    with_framework_exception_rendering do
      get "/definitely-not-a-real-page"

      assert_response :not_found
      assert_equal "text/html", response.media_type
      assert_no_match(/"error"\s*:/, response.body, "the JSON envelope must not leak onto non-/api paths")
    end
  end

  private

  # Stand in for the production image's /rails/spa/index.html.
  def with_spa_build
    config = Rails.application.config.x
    original = config.spa_index_path
    config.spa_index_path = file_fixture("spa_index.html")
    yield
  ensure
    config.spa_index_path = original
  end

  # Copied from Api::V1::ApiErrorsTest: with detailed exceptions on (the test
  # default) DebugExceptions renders its own page and config.exceptions_app —
  # the thing that produces the static 404 — never runs.
  def with_framework_exception_rendering
    env = Rails.application.env_config
    saved = env.slice("action_dispatch.show_exceptions", "action_dispatch.show_detailed_exceptions")
    env["action_dispatch.show_exceptions"] = :all
    env["action_dispatch.show_detailed_exceptions"] = false
    yield
  ensure
    env.merge!(saved)
  end

  def with_forgery_protection
    original = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    yield
  ensure
    ActionController::Base.allow_forgery_protection = original
  end
end
