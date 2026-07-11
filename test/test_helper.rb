ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"
require_relative "test_helpers/session_test_helper"

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    # Rate-limit counters (and any other cached state) must not leak between
    # tests — each parallel worker process has its own memory store.
    setup { Rails.cache.clear }

    # Add more helper methods to be used by all tests here...
  end
end
