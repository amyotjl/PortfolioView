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
      # The wall clock, in America/New_York. The ONE place the host clock is
      # read: everything that needs "what time is it in the market's timezone?"
      # (Prices::Freshness's expected-session walk-back) comes through here
      # rather than reaching for ActiveSupport::TimeZone itself.
      def now
        ActiveSupport::TimeZone[TIME_ZONE].now
      end

      # "Today" for all domain date logic — never the host clock's date.
      def today
        now.to_date
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

      # Last trading day on or before `date` — the effective "market close"
      # reference for an as-of query (nil when the cache has no day that early).
      # Backs the holdings pre-flight endpoint (backlog #030): a weekend/holiday
      # as_of resolves to the prior close.
      def last_day_on_or_before(date)
        calendar_scope.where(date: ..date).order(date: :desc).pick(:date)
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
