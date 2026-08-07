# One line in the boot log saying whether the /api/internal namespace is live
# (issue #75). Read InternalApi::Token for why this is observability rather than
# enforcement, and why the same distinction must never reach an HTTP response.
#
# Two deliberate choices about WHEN this runs:
#
#   * `after_initialize`, not `to_prepare` — `to_prepare` re-runs on every code
#     reload in development, which would reprint this on every file save.
#   * `Boot::Eligibility.process_kind`, NOT `Boot::Eligibility.eligible?`. Only a
#     web-server boot should print it (an initializer otherwise runs for
#     `db:prepare`, `assets:precompile` inside a Docker build, the console, and
#     every generator), but `eligible?` also honours DISABLE_BOOT_CATCH_UP — and
#     an operator who switches off the boot catch-up has not asked to lose this
#     diagnostic. The test env is excluded here for the same reason the suite
#     nils the variable: hermetic runs, quiet output.
Rails.application.config.after_initialize do
  next if Rails.env.test?
  next unless Boot::Eligibility.process_kind == :server

  InternalApi::Token.log_status
rescue StandardError => e
  # Boot must never die for a log line.
  Rails.logger.error("[InternalApi] status line failed: #{e.class}: #{e.message}")
end
