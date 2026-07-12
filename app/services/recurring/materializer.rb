module Recurring
  # Per-rule materialization core (docs/PLAN.md § Recurring materializer).
  #
  # Loops `while next_run_on <= today`, so one run after any amount of
  # downtime catches up every missed slot — each filled at its OWN historical
  # execution-date close, not today's:
  #
  #   execution date = first trading day >= slot (SPY calendar)
  #   fill price     = that day's official close
  #   shares         = dollar_amount / close rounded to 8 dp
  #                    (share-amount rules use share_amount directly)
  #
  # Each materialized transaction carries recurring_transaction_id +
  # scheduled_for; the partial unique index on that pair makes double runs
  # insert nothing extra (the pre-check advances past an already-filled slot,
  # and a raced insert is rescued and advanced identically). Advancement is
  # computed from the ANCHOR via RecurringTransaction#next_slot_after — no
  # end-of-month drift. Inserts bump the portfolio's series_version via the
  # Transaction model callback.
  #
  # The loop halts without advancing when a slot cannot be filled yet:
  #   :awaiting_data  — no trading day >= slot in the cache, or it is still in
  #                     the future (e.g. a Saturday slot before Monday's close
  #                     lands); tomorrow's run retries the same slot
  #   :missing_price  — the instrument has no close on the execution date
  class Materializer
    Result = Data.define(:filled, :stopped)

    def self.call(...) = new(...).call

    def initialize(rule:, today: Trading::Calendar.today)
      @rule = rule
      @today = today
    end

    def call
      return Result.new(filled: 0, stopped: :inactive) unless rule.active?

      filled = 0
      stopped = :caught_up

      while rule.next_run_on <= today
        slot = rule.next_run_on

        execution_date = Trading::Calendar.first_day_on_or_after(slot)
        if execution_date.nil? || execution_date > today
          stopped = :awaiting_data
          break
        end

        close = DailyPrice.where(instrument_id: rule.instrument_id, date: execution_date).pick(:close)
        if close.nil?
          stopped = :missing_price
          break
        end

        filled += 1 if fill_slot(slot, execution_date, close)
      end

      Result.new(filled: filled, stopped: stopped)
    end

    private

    attr_reader :rule, :today

    # Insert + advance atomically per slot: a crash between them self-heals on
    # the next run (the pre-check finds the filled slot and only advances).
    def fill_slot(slot, execution_date, close)
      inserted = false
      ApplicationRecord.transaction do
        unless Transaction.exists?(recurring_transaction_id: rule.id, scheduled_for: slot)
          Transaction.create!(
            portfolio_id: rule.portfolio_id,
            instrument_id: rule.instrument_id,
            side: rule.side,
            kind: "normal",
            shares: shares_at(close),
            price: close,
            fees: 0,
            executed_on: execution_date,
            recurring_transaction: rule,
            scheduled_for: slot
          )
          inserted = true
        end
        advance_past(slot)
      end
      inserted
    rescue ActiveRecord::RecordNotUnique
      # A concurrent run won the partial-unique-index race for this slot; it
      # is filled — just advance past it.
      advance_past(slot)
      false
    end

    def advance_past(slot)
      rule.update!(next_run_on: rule.next_slot_after(slot))
    end

    def shares_at(close)
      case rule.amount_type
      when "dollars" then (rule.dollar_amount / close).round(8)
      else rule.share_amount
      end
    end
  end
end
