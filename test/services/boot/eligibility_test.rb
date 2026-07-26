require "test_helper"

# The fourth acceptance criterion of issue #55 lives here: an initializer runs
# in EVERY Rails process, so the boot catch-up must be able to tell a web-server
# boot from `rails db:migrate`, `assets:precompile`, a console, or this suite.
class Boot::EligibilityTest < ActiveSupport::TestCase
  test "the process running this suite is not eligible" do
    assert_not Boot::Eligibility.eligible?,
               "the test environment must never enqueue at boot — the suite asserts on enqueued jobs"
  end

  test "the test environment is never eligible, even in a server process" do
    assert_not Boot::Eligibility.eligible?(kind: :server)
  end

  test "a server boot outside the test environment is eligible" do
    assert Boot::Eligibility.eligible?(env: env("production"), disabled: false, kind: :server)
    assert Boot::Eligibility.eligible?(env: env("development"), disabled: false, kind: :server)
  end

  test "rake, console and unrecognized processes are never eligible" do
    %i[rake console other].each do |kind|
      assert_not Boot::Eligibility.eligible?(env: env("production"), disabled: false, kind: kind),
                 "a #{kind} process must not enqueue boot catch-up work"
    end
  end

  test "DISABLE_BOOT_CATCH_UP switches off an otherwise eligible boot" do
    assert_not Boot::Eligibility.eligible?(env: env("production"), disabled: true, kind: :server)
  end

  test "rails db:migrate and assets:precompile are rake processes, not servers" do
    assert_equal :rake, kind_of_process(rake_tasks: [ "db:migrate" ])
    assert_equal :rake, kind_of_process(rake_tasks: [ "db:prepare" ])
    assert_equal :rake, kind_of_process(rake_tasks: [ "assets:precompile" ])
  end

  test "a rake process is still rake even if something has loaded Rails::Server" do
    assert_equal :rake, kind_of_process(rails_server: true, rake_tasks: [ "db:migrate" ])
  end

  test "rails server and a bare puma are both servers" do
    assert_equal :server, kind_of_process(rails_server: true)
    assert_equal :server, kind_of_process(program_name: "/usr/local/bundle/bin/puma")
    # Puma rewrites $0 in cluster workers.
    assert_equal :server, kind_of_process(program_name: "puma: cluster worker 1: 42 [app]")
  end

  test "rails console is a console and rails runner is neither" do
    assert_equal :console, kind_of_process(rails_console: true)
    assert_equal :other, kind_of_process(program_name: "bin/rails")
  end

  private

  def env(name) = ActiveSupport::StringInquirer.new(name)

  def kind_of_process(program_name: "bin/rails", rails_server: false, rails_console: false, rake_tasks: [])
    Boot::Eligibility.process_kind(program_name: program_name, rails_server: rails_server,
                                   rails_console: rails_console, rake_tasks: rake_tasks)
  end
end
