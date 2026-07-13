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

    # Route uncaught exceptions (500s, and anything the middleware turns into a
    # status) through ErrorsController so /api answers with the JSON error
    # envelope instead of a static HTML page (docs/PLAN.md § API contract).
    # A lambda (not a direct reference) so the constant is resolved lazily at
    # request time rather than during boot autoloading.
    config.exceptions_app = ->(env) { ErrorsController.action(:show).call(env) }
  end
end
