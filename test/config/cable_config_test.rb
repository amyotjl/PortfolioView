require "test_helper"

# Issue #74. The defect was a CONFIGURATION contradiction, not a code path, so
# this is where it has to be guarded: production declared `adapter: redis` for
# Action Cable while the whole stack exists to need no Redis, and `db:prepare`
# created an `app_production_cable` database with no schema to load into it.
#
# Read as source/YAML rather than through Rails' own accessors on purpose — the
# test env's cable adapter is `test` and its database config has no `cable` entry
# at all, so asking the running app about it would assert nothing about the
# production values that were actually wrong.
class CableConfigTest < ActiveSupport::TestCase
  CABLE = YAML.load_file(Rails.root.join("config/cable.yml")).freeze
  DATABASE = YAML.load_file(Rails.root.join("config/database.yml"), aliases: true).freeze

  # Adapters that need a service this deployment does not run. Solid Queue and
  # Solid Cache are Postgres-backed precisely so that no Redis is required
  # (docs/PLAN.md § Deployment), and no compose profile starts one.
  UNAVAILABLE_ADAPTERS = %w[redis].freeze

  test "no environment declares a cable adapter this stack cannot provide" do
    CABLE.each do |env, config|
      adapter = config["adapter"]

      assert_not_includes UNAVAILABLE_ADAPTERS, adapter,
        "#{env} declares adapter #{adapter.inspect}, which needs a service this stack does not run"
    end
  end

  test "no live cable.yml line reaches for a Redis URL" do
    # The old production block defaulted to redis://localhost:6379/1, which is
    # what made a missing service look like a working configuration.
    #
    # Comment lines are stripped first, and that is not a loophole: the file's
    # comment explains the contradiction being removed and has to be able to name
    # `redis` and `REDIS_URL` to do so. Only the settings are asserted on.
    settings = Rails.root.join("config/cable.yml").read
      .lines.grep_v(/\A\s*#/).join

    assert_no_match(/REDIS_URL|redis:\/\//, settings)
  end

  test "solid_cable is not declared as an adapter while its schema does not exist" do
    # The other half of the contradiction, in the direction someone is most
    # likely to "fix" it: switching the adapter to solid_cable without generating
    # db/cable_schema.rb produces a cable database that is created and empty
    # again, which is the state this issue was filed about.
    schema_exists = Rails.root.join("db/cable_schema.rb").exist?

    CABLE.each_value do |config|
      next unless config["adapter"] == "solid_cable"

      assert schema_exists,
        "solid_cable needs db/cable_schema.rb, or db:prepare creates an unusable cable database"
    end
  end

  test "production declares no cable database while nothing loads a schema into one" do
    cable = DATABASE.fetch("production")["cable"]
    schema_exists = Rails.root.join("db/cable_schema.rb").exist?

    if cable
      assert schema_exists,
        "a declared cable database means db:prepare CREATES app_production_cable; " \
        "without db/cable_schema.rb it is left empty and unusable (#74)"
    else
      assert_not schema_exists,
        "db/cable_schema.rb exists, so the cable database should be declared and loaded"
    end
  end

  test "the queue and cache databases ARE still declared — this must not have overreached" do
    production = DATABASE.fetch("production")

    assert_equal "app_production_queue", production.dig("queue", "database")
    assert_equal "app_production_cache", production.dig("cache", "database")
    assert Rails.root.join("db/queue_schema.rb").exist?
    assert Rails.root.join("db/cache_schema.rb").exist?
  end
end
