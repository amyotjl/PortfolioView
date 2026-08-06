require_relative "boot"

require "rails/all"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module App
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.1

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib(ignore: %w[assets tasks])

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # config.time_zone = "Central Time (US & Canada)"
    # config.eager_load_paths << Rails.root.join("extras")

    # ACTION CABLE IS NOT MOUNTED (issue #74). `require "rails/all"` above loads
    # the framework, and its railtie otherwise mounts a WebSocket endpoint at
    # /cable in every environment. Measured on the production stack during #58: a
    # plain GET answered 404, but a real **upgrade handshake answered 101 Switching
    # Protocols** — an endpoint that accepts connections for a feature this app
    # does not have. Nothing in the app broadcasts, `app/channels` holds only the
    # generated `ApplicationCable::Connection`, and the frontend has no
    # `@rails/actioncable` dependency and no consumer.
    #
    # `nil` removes the route entirely, which is the narrow form of #74's
    # preferred option ("don't mount it") — it needs no change to `rails/all`, so
    # ActiveJob/ActiveRecord/ActionMailer keep loading exactly as before.
    #
    # THREE THINGS MUST CHANGE TOGETHER if real-time features are ever wanted, and
    # doing only the first leaves the contradiction this issue was filed for:
    #   1. this line (restore the mount),
    #   2. `config/cable.yml` — switch production to `solid_cable` (the gem is
    #      already in the Gemfile) and generate `db/cable_schema.rb`,
    #   3. `config/database.yml` — re-add the production `cable` database so
    #      `db:prepare` creates AND loads it.
    # Also drop "/cable" from the SPA catch-all constraint in `config/routes.rb`,
    # which exists so unmounting does not hand the Vue shell to /cable.
    config.action_cable.mount_path = nil

    # Route uncaught exceptions (500s, and anything the middleware turns into a
    # status) through ErrorsController so /api answers with the JSON error
    # envelope instead of a static HTML page (docs/PLAN.md § API contract).
    # A lambda (not a direct reference) so the constant is resolved lazily at
    # request time rather than during boot autoloading.
    config.exceptions_app = ->(env) { ErrorsController.action(:show).call(env) }

    # Where SpaController looks for the Vite-built index.html. The production
    # image writes it here (Dockerfile stage 4) instead of public/ so the static
    # file server can't serve it for "/" with the far-future asset cache headers.
    # Absent in a dev checkout, which is why SpaController tolerates a miss.
    config.x.spa_index_path = Rails.root.join("spa", "index.html")
  end
end
