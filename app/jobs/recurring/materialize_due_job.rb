module Recurring
  # Nightly materializer fan-in (docs/PLAN.md § Recurring materializer):
  # selects every active rule whose next_run_on is due and hands each to
  # Recurring::Materializer, which catches up all missed slots in one pass.
  # Scheduled daily x7 pinned to America/New_York (config/recurring.yml) and
  # idempotent, so a night with the machine off is simply caught up by the
  # next run — same catch-up-on-boot story as the price sync.
  class MaterializeDueJob < ApplicationJob
    queue_as :default

    def perform
      today = Trading::Calendar.today

      RecurringTransaction.where(active: true).where(next_run_on: ..today).find_each do |rule|
        result = Recurring::Materializer.call(rule: rule, today: today)
        Rails.logger.info(
          "[#{self.class.name}] rule ##{rule.id}: filled #{result.filled} slot(s), stopped: #{result.stopped}"
        )
      rescue StandardError => e
        # One broken rule must not starve the rest of the night's rules.
        Rails.logger.error("[#{self.class.name}] rule ##{rule.id} failed: #{e.class}: #{e.message}")
      end
    end
  end
end
