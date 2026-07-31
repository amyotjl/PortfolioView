module Prices
  # "How current is the price cache?" — THE staleness predicate for the whole
  # app (issue #56, unified with the boot catch-up by issue #59).
  #
  # There is exactly one definition of "behind", and it lives here. Both callers
  # consume this result and neither computes a reference day of its own:
  #
  #   * GET /api/v1/sync (SyncStatusSerializer) — the snapshot #57's Settings
  #     page renders.
  #   * Boot::CatchUp — the on-boot "did we sleep through a session?" check.
  #
  # They used to disagree. #55 compared against `max(Calendar.last_day,
  # last_expected_session)` with a 22:00 ET cutoff; #56 compared against the
  # most recent weekday STRICTLY BEFORE today with no cutoff. On a Monday at
  # 23:00 ET with the cache current through Friday, the boot check enqueued a
  # sync while the API reported `stale: false` — the UI said "prices are
  # current" while the app was fetching. See the divergence table on issue #59.
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
  # SPY is a seeded benchmark and therefore always `referenced`, and
  # Prices::SeriesWriter keeps its latest_price_on equal to the newest SPY price
  # row — so `Calendar.last_day` is derived FROM the same cache the max is taken
  # over and can never be ahead of it. A box asleep for a week has a week-old
  # cache AND a week-old calendar, and they agree.
  #
  # Only the wall clock knows. So staleness is `max(latest_price_on)` over
  # referenced instruments vs `expected_session`: the most recent WEEKDAY in
  # America/New_York whose closes should already have been fetched, where
  # "today counts once it is past 22:00 ET" — the slot config/recurring.yml
  # schedules the nightly sync in, and the hour by which US EOD data has landed.
  # (#56's cutoff-free "strictly before today" under-reported staleness for a
  # full evening every weekday: a 22:15 boot fetched today's closes while the
  # API still called the cache fresh.)
  #
  # Weekend-aware and deliberately NOT holiday-aware: the app has no holiday
  # table by design (the price cache IS the calendar). The consequence is
  # precise and worth stating rather than debugging later — on the ~9 US market
  # holidays a year, and the evening of each, `stale` reads true while the cache
  # is in fact perfectly current. That direction is chosen on purpose: a false
  # "stale" costs one idempotent no-op delta sync, a false "fresh" costs the
  # user trusting old numbers.
  #
  # BOOT SAFETY (issue #59). This is now reachable from an initializer via
  # Boot::CatchUp, where the schema may not exist yet, so it inherits that
  # class's contract: it may only touch tables Boot::CatchUp::REQUIRED_TABLES
  # already verified (instruments, daily_prices, transactions,
  # recurring_transactions, benchmarks) — and nothing else. In particular the
  # sync-claim lease lives in the CACHE store, whose database is separate and
  # may be unmigrated at boot; `check_pending: false` skips that read. Adding a
  # query here against any other table would reintroduce a boot crash.
  class Freshness
    # US EOD data has landed by this hour (ET) — the same slot
    # config/recurring.yml schedules the nightly sync in. Before it, the current
    # day's close is not yet expected and its absence is not staleness.
    DATA_LANDS_AT_HOUR = 22

    # latest_price_on    — MAX(latest_price_on) over referenced instruments; nil
    #                      when nothing is cached yet (fresh database). This is
    #                      the DISPLAY value ("prices current through ...").
    # last_trading_day   — newest date the trading calendar knows; nil likewise.
    # expected_session   — the most recent session whose closes are due (below).
    # stale              — a sync is worth running: the newest thing we have is
    #                      older than the newest thing we should have.
    # instruments_behind — how many referenced instruments are individually
    #                      behind expected_session. Integer, never nil, 0 on an
    #                      empty database. A MAX cannot see one lagging ticker
    #                      whose fetch failed while SPY's succeeded (SPY is
    #                      always in the set, so it holds the max up); this
    #                      count can. `stale` implies this is >= 1, never the
    #                      other way round.
    # pending_since      — when the currently-held sync claim was made, or nil.
    Result = Data.define(:latest_price_on, :last_trading_day, :expected_session,
                         :stale, :instruments_behind, :pending_since) do
      def pending? = !pending_since.nil?

      # The enqueue predicate: is there anything a sync could actually catch up?
      # Subsumes `stale` (whoever holds the max is itself behind) AND the
      # single-laggard case AND "nothing is referenced, so there is nothing to
      # fetch" (count 0).
      def behind? = instruments_behind.positive?
    end

    def self.call(...) = new(...).call

    # now:           the wall clock, coerced to America/New_York. Injectable so
    #                the cutoff is testable without travel_to gymnastics.
    # check_pending: read the sync-claim lease from the cache store. False for
    #                boot-time callers — see BOOT SAFETY above.
    def initialize(now: Trading::Calendar.now, check_pending: true)
      @now = now.in_time_zone(Trading::Calendar::TIME_ZONE)
      @check_pending = check_pending
    end

    def call
      expected = expected_session
      latest_price_on, instruments_behind = measure(expected)

      Result.new(
        latest_price_on: latest_price_on,
        last_trading_day: Trading::Calendar.last_day,
        expected_session: expected,
        # A nil max means no referenced instrument has ever been priced, which
        # is exactly the state a fresh install is in: tell the user to sync
        # rather than claiming to be up to date.
        stale: latest_price_on.nil? || latest_price_on < expected,
        instruments_behind: instruments_behind,
        pending_since: check_pending ? Prices::SyncTrigger.pending_since : nil
      ).freeze
    end

    private

    attr_reader :now, :check_pending

    # ONE aggregate over the instruments the nightly sync actually fans out
    # over. An instrument nothing references is deliberately never synced (it
    # burns provider quota for no one), so its stale prices must not be reported
    # as the app's staleness either — Instrument.referenced is the same scope the
    # fan-out uses.
    #
    # Both numbers come from a single row: no N+1, no second pass, and no rows
    # loaded. A referenced instrument with a NULL latest_price_on counts as
    # behind — it has never been priced at all.
    def measure(expected)
      Instrument.referenced.pick(
        Arel.sql("MAX(latest_price_on)"),
        Arel.sql(Instrument.sanitize_sql_array(
          [ "COUNT(*) FILTER (WHERE latest_price_on IS NULL OR latest_price_on < ?)", expected ]
        ))
      )
    end

    # THE WALL-CLOCK WALK-BACK. The most recent weekday whose closes should
    # already be cached, treating today as due once the 22:00 ET data drop has
    # passed.
    #
    # NEVER VALID FOR DOMAIN MATH. This is the only date arithmetic in the app
    # that is not Trading::Calendar's, and it exists for exactly one reason:
    # Trading::Calendar is cache-derived (a trading day is a day SPY has a row
    # for), so it structurally cannot answer "has a session happened that we
    # never fetched?" — the question this predicate exists to ask. It makes no
    # claim about the real trading calendar: it does not know holidays, and it
    # must never decide an as-of date, a valuation day, or a benchmark cash-flow
    # day. Trading::Calendar remains the only calendar any money calculation may
    # consult.
    def expected_session
      date = now.hour < DATA_LANDS_AT_HOUR ? now.to_date - 1 : now.to_date
      date -= 1 while date.saturday? || date.sunday?
      date
    end
  end
end
