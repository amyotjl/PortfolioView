module Prices
  # "How current is the price cache?" — the global, portfolio-independent
  # data-freshness snapshot behind GET /api/v1/sync (issue #56, rendered by
  # #57's Settings page).
  #
  # Global on purpose. /summary's `as_of` is the obvious-looking source and is
  # the WRONG one for this: it is portfolio-scoped, and it is nil for a
  # portfolio with no price coverage at all (an imported CAD portfolio does
  # exactly this — see docs/STATUS.md), which would render as "never synced"
  # when the truth is "this portfolio has no prices". Settings is not
  # portfolio-scoped, so it asks the cache directly.
  #
  # THE STALENESS RULE, and why it is not the comparison PLAN.md words it as.
  # docs/PLAN.md § Deployment describes the boot catch-up as firing when
  # "max(latest_price_on) is behind the last trading day". Taken literally
  # against Trading::Calendar that comparison is DEGENERATE and can never be
  # true: a trading day is defined as a date where SPY has a daily_prices row,
  # SPY is a referenced instrument, and its latest_price_on tracks that same
  # max — so `Calendar.last_day` is derived FROM the cache and can never be
  # ahead of it. A box asleep for a week has a week-old cache AND a week-old
  # calendar, and they agree.
  #
  # The only thing that knows the cache has fallen behind is the wall clock, so
  # staleness is `last_trading_day` vs the most recent WEEKDAY strictly before
  # today in America/New_York. Strictly before, because the nightly sync runs at
  # 22:00 ET (config/recurring.yml) — today's close does not exist for most of
  # today.
  #
  # This is weekend-aware and deliberately NOT holiday-aware: the app has no
  # holiday table by design (the price cache IS the calendar). The consequence
  # is precise and worth stating rather than debugging later — on the ~9 US
  # market holidays a year, and the day after each, `stale` reads true while
  # the cache is in fact perfectly current. That direction is chosen on
  # purpose: a false "stale" costs one idempotent no-op sync, a false "fresh"
  # costs the user trusting old numbers.
  class Freshness
    # latest_price_on   — MAX(latest_price_on) over referenced instruments; nil
    #                     when nothing is cached yet (fresh database).
    # last_trading_day  — newest date the trading calendar knows; nil likewise.
    # stale             — a sync is worth running (see above).
    # pending_since     — when the currently-held sync claim was made, or nil.
    Result = Data.define(:latest_price_on, :last_trading_day, :stale, :pending_since) do
      def pending? = !pending_since.nil?
    end

    def self.call(...) = new(...).call

    def initialize(today: Trading::Calendar.today)
      @today = today
    end

    def call
      last_trading_day = Trading::Calendar.last_day
      pending_since = Prices::SyncTrigger.pending_since

      Result.new(
        latest_price_on: Instrument.referenced.maximum(:latest_price_on),
        last_trading_day: last_trading_day,
        stale: stale?(last_trading_day),
        pending_since: pending_since
      ).freeze
    end

    private

    attr_reader :today

    # An empty calendar means nothing has ever been fetched — stale, so a fresh
    # database tells the user to sync rather than claiming to be up to date.
    def stale?(last_trading_day)
      return true if last_trading_day.nil?

      last_trading_day < expected_trading_day
    end

    # The most recent weekday strictly before ET today.
    def expected_trading_day
      date = today - 1
      date -= 1 while date.saturday? || date.sunday?
      date
    end
  end
end
