module Prices
  # The nightly fan-out (docs/PLAN.md § Price pipeline / § Trading calendar).
  #
  # Scheduled DAILY, 7 days a week, pinned to America/New_York (see
  # config/recurring.yml) — deliberately NOT a weekday cron, which misfires
  # around midnight when the supervisor's clock is UTC. Instead the job self-
  # gates: a weekend run is a cheap idempotent no-op, and a holiday run fans out
  # jobs whose delta fetches simply find no new rows (idempotent).
  #
  # It enqueues one FetchInstrumentJob per active instrument, staggered so the
  # fan-out stays under Tiingo's 50/hr pacing window (the per-fetch Budget
  # breaker is the hard cap; this stagger keeps most nights off the brakes).
  class DailySyncJob < ApplicationJob
    queue_as :default

    def perform
      today = ActiveSupport::TimeZone[PriceProvider::TIME_ZONE].today
      if weekend?(today)
        Rails.logger.info("[#{self.class.name}] #{today} is a weekend (non-trading day); no-op")
        return
      end

      per_hour = pace
      enqueued = 0
      Instrument.referenced.order(:id).find_each.with_index do |instrument, index|
        wait = (index / per_hour).hours
        Prices::FetchInstrumentJob.set(wait: wait).perform_later(instrument.id)
        enqueued += 1
      end
      Rails.logger.info("[#{self.class.name}] #{today}: fanned out #{enqueued} fetch(es), paced #{per_hour}/hr")
    end

    private

    def weekend?(date) = date.saturday? || date.sunday?

    # The breaker's hourly pacing window is the fan-out's pacing helper.
    def pace
      PriceProvider::Budget.new("tiingo").hourly_limit || 50
    end
  end
end
