module Prices
  # Shared retry/discard policy for the price-pipeline jobs, keyed off the
  # PriceProvider typed-error taxonomy (docs/PLAN.md § Price pipeline). The
  # adapters raise distinct classes precisely so these jobs can react
  # differently; do not collapse them into a generic rescue.
  #
  #   * ServerError        -> retry with polynomial backoff (transient 5xx/net)
  #   * RateLimited        -> reschedule honoring the provider's retry_after
  #   * BudgetExceeded     -> (a RateLimited) reschedule until the window resets
  #   * UnknownSymbol      -> discard and flag (unknown everywhere; retrying is
  #                           pointless and would burn quota)
  #   * ConfigurationError -> discard (a missing/rejected key is not transient)
  #   * RecordNotFound     -> discard (the instrument was deleted mid-flight)
  #
  # RateLimited/BudgetExceeded are rescheduled inside #perform (via
  # #reschedule_on_rate_limit) rather than a class-level retry_on so the wait
  # can honor the typed error's retry_after, and so the fetch job's failover can
  # intercept them before they ever escalate to a plain retry.
  module ProviderErrorHandling
    extend ActiveSupport::Concern

    # A budget/pacing window resets within a day, so a rescheduled job may wait
    # out several windows; this bounds the reschedule loop so a permanently
    # exhausted key can't reschedule forever.
    MAX_RATE_LIMIT_RETRIES = 24

    included do
      retry_on PriceProvider::ServerError, wait: :polynomially_longer, attempts: 5

      discard_on ActiveRecord::RecordNotFound
      discard_on PriceProvider::ConfigurationError
      discard_on PriceProvider::UnknownSymbol do |job, error|
        job.send(:flag_unknown_symbol, error)
      end
    end

    private

    # Re-enqueue the job after the provider's advertised cool-off. BudgetExceeded
    # is a RateLimited, so this covers both. Returns a symbol for the caller/tests.
    def reschedule_on_rate_limit(error)
      if executions > MAX_RATE_LIMIT_RETRIES
        Rails.logger.error("[#{self.class.name}] giving up after #{executions} attempts: #{error.message}")
        return :gave_up
      end

      wait = (error.retry_after || 60).to_i.clamp(1, 86_400)
      Rails.logger.info(
        "[#{self.class.name}] #{error.class.name.demodulize}; rescheduling in #{wait}s (attempt #{executions})"
      )
      retry_job(wait: wait.seconds)
      :rescheduled
    end

    def flag_unknown_symbol(error)
      instrument_id = arguments.first
      Rails.logger.warn(
        "[#{self.class.name}] unknown symbol for instrument=#{instrument_id}: #{error.message}; discarding"
      )
      Rails.error.report(error, handled: true, context: { instrument_id: instrument_id })
    end
  end
end
