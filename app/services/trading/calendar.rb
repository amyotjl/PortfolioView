module Trading
  # The trading calendar (docs/PLAN.md § Trading calendar & time).
  #
  # A trading day is a date where the calendar instrument (SPY) has a
  # daily_prices row — the price cache IS the calendar, no holiday tables.
  # All "what day is it" logic runs in America/New_York.
  #
  # Every lookup is a single query that JOINs instruments on the symbol
  # (deliberately not a separate `Instrument.find_by` + prices query), so a
  # caller composing a calendar lookup into a sweep — Holdings::Calculator's
  # 3-query contract — pays exactly one query for it.
  class Calendar
    TIME_ZONE = "America/New_York".freeze
    CALENDAR_SYMBOL = "SPY".freeze

    class << self
      # "Today" for all domain date logic — never the host clock's date.
      def today
        ActiveSupport::TimeZone[TIME_ZONE].today
      end

      # Trading days in from..to, ascending.
      def days_between(from, to)
        calendar_scope.where(date: from..to).order(:date).pluck(:date)
      end

      # First trading day on or after `date` (nil when the price cache does
      # not extend that far yet).
      def first_day_on_or_after(date)
        calendar_scope.where(date: date..).order(:date).pick(:date)
      end

      # Most recent trading day known to the cache.
      def last_day
        calendar_scope.maximum(:date)
      end

      private

      def calendar_scope
        DailyPrice.joins(:instrument).where(instruments: { symbol: CALENDAR_SYMBOL })
      end
    end
  end
end
