module Boot
  # Decides whether THIS process should run the boot catch-up (issue #55,
  # docs/PLAN.md § Deployment).
  #
  # An initializer runs in EVERY Rails process, not just the web server:
  # `rails db:create`, `db:migrate`, `db:prepare`, `assets:precompile` inside a
  # Docker build, `rails console`, `rails runner`, generators, and the test
  # runner all boot the application. Most of those run before the tables the
  # catch-up queries exist, some before the database exists at all, and none of
  # them should be enqueueing background work.
  #
  # So this is an ALLOWLIST, not a denylist: only a web-server boot is eligible.
  # A denylist silently mis-fires the day a new command shows up (and "the
  # Docker build enqueued a price sync" is a bug nobody goes looking for),
  # whereas an allowlist's failure mode is the catch-up simply not running —
  # which the boot log makes obvious, because Boot::CatchUp logs its outcome
  # either way.
  #
  # Every input is an injectable keyword with a real default, so the decision
  # table is testable without spawning processes.
  class Eligibility
    DISABLE_ENV = "DISABLE_BOOT_CATCH_UP".freeze

    class << self
      def eligible?(env: Rails.env, disabled: ENV[DISABLE_ENV].present?, kind: process_kind)
        return false if env.test?   # the suite asserts on enqueued jobs; boot must not seed them
        return false if disabled    # operator escape hatch (a boot loop, an offline box)

        kind == :server
      end

      # :server | :console | :rake | :other
      #
      # Note the ordering is defensive rather than load-bearing: anything that
      # is not :server is ineligible anyway. Naming the other kinds is for the
      # log line, which is the only way to diagnose "why didn't it sync?".
      def process_kind(program_name: $PROGRAM_NAME,
                       rails_server: rails_const?(:Server),
                       rails_console: rails_const?(:Console),
                       rake_tasks: rake_top_level_tasks)
        return :console if rails_console
        return :rake    if rake_tasks.any?
        return :server  if rails_server || puma?(program_name)

        :other
      end

      private

      # `rails server` defines Rails::Server before it initializes the app;
      # `rails console` defines Rails::Console the same way. Neither constant
      # exists under a rake task or `rails runner`.
      def rails_const?(name) = ::Rails.const_defined?(name)

      # `bundle exec puma -C config/puma.rb` (the production entrypoint) never
      # defines Rails::Server. In cluster mode Puma rewrites $0 to
      # "puma: cluster worker 0: 123 [app]", which still starts with "puma".
      def puma?(program_name) = File.basename(program_name.to_s).start_with?("puma")

      # Set by Rake (and by Rails::Command::RakeCommand, which shells into Rake)
      # before the :environment task initializes the app — so by the time
      # after_initialize runs, `rails db:migrate` reports ["db:migrate"].
      # An unparsed/absent Rake reports none.
      def rake_top_level_tasks
        return [] unless defined?(::Rake) && ::Rake.respond_to?(:application)

        ::Rake.application.top_level_tasks
      rescue StandardError
        []
      end
    end
  end
end
