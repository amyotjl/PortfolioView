# Catch-up-on-boot for the nightly jobs (issue #55, docs/PLAN.md § Deployment).
#
# The machine will not reliably be awake at 22:00 ET, so app start is the second
# trigger for the price sync and the recurring materializer. All of the logic —
# and all of the "is this database even usable yet?" guarding — lives in
# Boot::CatchUp; whether this process is one that should run it at all is
# Boot::Eligibility's decision (only a web-server boot is; not rake, not the
# console, not the test runner).
#
# after_initialize, deliberately NOT to_prepare: `to_prepare` re-runs on every
# code reload in development, so it would re-enqueue a sync on every file save.
# This block runs exactly once per process, after eager loading.
Rails.application.config.after_initialize do
  next unless Boot::Eligibility.eligible?

  Boot::CatchUp.call
rescue StandardError => e
  # Belt and braces: Boot::CatchUp already swallows its own failures, so
  # reaching here means the guard itself broke. Boot is still not allowed to
  # die for the catch-up check.
  Rails.logger.error("[Boot::CatchUp] initializer failed: #{e.class}: #{e.message}")
end
