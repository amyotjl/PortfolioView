require "test_helper"

module Prices
  # issue #56: the global price-cache freshness snapshot behind GET /api/v1/sync.
  # issue #59: and THE staleness predicate for the whole app — Boot::CatchUp
  # consumes this same result rather than computing a reference day of its own.
  class FreshnessTest < ActiveSupport::TestCase
    include DomainTestHelper

    # A wall-clock instant in America/New_York — the only clock this predicate
    # reads. Defined before the constants below because they call it.
    def self.et(year, month, day, hour, minute = 0)
      ActiveSupport::TimeZone[Trading::Calendar::TIME_ZONE].local(year, month, day, hour, minute).freeze
    end

    # A Wednesday, so the walk-back lands on an unremarkable Tuesday and no
    # weekend logic is implicitly under test. MORNING is before the 22:00 ET
    # data drop (today's close is not due yet), NIGHT is after it.
    WEDNESDAY = Date.new(2026, 7, 22).freeze
    TUESDAY   = Date.new(2026, 7, 21).freeze
    MORNING   = et(2026, 7, 22, 10)
    NIGHT     = et(2026, 7, 22, 22, 15)

    # -- the fresh-database null case ---------------------------------------

    test "an empty database reports nulls and is stale" do
      result = Prices::Freshness.call(now: MORNING)

      assert_nil result.latest_price_on, "nothing cached yet"
      assert_nil result.last_trading_day, "no calendar yet"
      assert result.stale, "a database with no prices must tell the user to sync"
      assert_not result.pending?
      assert_nil result.pending_since
    end

    # An empty database has nothing to be behind: the count is over referenced
    # instruments and there are none. It must be 0, not nil and not a crash —
    # Boot::CatchUp keys its enqueue off exactly this.
    test "an empty database reports zero instruments behind, not nil" do
      result = Prices::Freshness.call(now: MORNING)

      assert_equal 0, result.instruments_behind
      assert_not result.behind?, "there is nothing to fetch, so a fan-out would be noise"
    end

    test "an empty database still serializes, with nulls the UI can render" do
      json = SyncStatusSerializer.new(Prices::Freshness.call(now: MORNING)).as_json

      assert_nil json.dig(:sync, :latest_price_on)
      assert_nil json.dig(:sync, :last_trading_day)
      assert_nil json.dig(:sync, :requested_at)
      assert_equal true, json.dig(:sync, :stale)
      assert_equal false, json.dig(:sync, :pending)
      assert_equal 0, json.dig(:sync, :instruments_behind)
    end

    # -- the populated case --------------------------------------------------

    test "a cache current through yesterday is NOT stale" do
      seed_calendar_through(TUESDAY)

      result = Prices::Freshness.call(now: MORNING)

      assert_equal TUESDAY, result.latest_price_on
      assert_equal TUESDAY, result.last_trading_day
      assert_equal TUESDAY, result.expected_session
      assert_not result.stale, "the newest expected close has landed"
      assert_equal 0, result.instruments_behind
    end

    test "latest_price_on is the MAX across referenced instruments" do
      seed_calendar_through(TUESDAY)
      aapl = create_instrument(symbol: "AAPL")
      refer_to(aapl)
      aapl.update!(latest_price_on: Date.new(2026, 7, 20)) # a laggard

      result = Prices::Freshness.call(now: MORNING)

      assert_equal TUESDAY, result.latest_price_on,
        "MAX, not MIN — docs/PLAN.md words the boot catch-up in terms of max(latest_price_on)"
    end

    test "an UNreferenced instrument is ignored, however current it is" do
      seed_calendar_through(TUESDAY)
      create_instrument(symbol: "ZZZZ").update!(latest_price_on: Date.new(2030, 1, 1))

      assert_equal TUESDAY, Prices::Freshness.call(now: MORNING).latest_price_on,
        "the sync only fans out over referenced instruments, so only they define freshness"
    end

    # -- the stale branch ----------------------------------------------------

    test "a cache a week behind IS stale" do
      seed_calendar_through(Date.new(2026, 7, 15))

      result = Prices::Freshness.call(now: MORNING)

      assert result.stale, "the box was asleep; the newest expected close never landed"
      assert_equal Date.new(2026, 7, 15), result.last_trading_day
    end

    test "one day behind is already stale" do
      seed_calendar_through(Date.new(2026, 7, 20)) # Monday, expected is Tuesday

      assert Prices::Freshness.call(now: MORNING).stale
    end

    # -- the 22:00 ET cutoff (issue #59: #55's semantics, adopted) -----------
    #
    # The whole reason the two implementations diverged. #56 compared against
    # "the most recent weekday STRICTLY BEFORE today", which under-reports
    # staleness for a full evening every weekday: between 22:00 and midnight the
    # nightly job has already run and today's closes ARE expected.

    test "today's close is not yet expected before the 22:00 ET data drop" do
      seed_calendar_through(TUESDAY)

      result = Prices::Freshness.call(now: MORNING)

      assert_equal TUESDAY, result.expected_session
      assert_not result.stale
    end

    test "today's close IS expected after the 22:00 ET data drop" do
      seed_calendar_through(TUESDAY)

      result = Prices::Freshness.call(now: NIGHT)

      assert_equal WEDNESDAY, result.expected_session,
        "past the nightly slot, today is the session whose closes should be cached"
      assert result.stale, "cutoff-free 'strictly before today' would call this fresh all evening"
      assert_equal 1, result.instruments_behind
    end

    test "the cutoff flips exactly at 22:00 ET, not at 21:59" do
      seed_calendar_through(TUESDAY)

      assert_equal TUESDAY, Prices::Freshness.call(now: et(2026, 7, 22, 21, 59)).expected_session
      assert_equal WEDNESDAY, Prices::Freshness.call(now: et(2026, 7, 22, 22, 0)).expected_session
    end

    # The divergence that motivated issue #59, pinned as a test: Monday 23:00 ET
    # with the cache current through Friday. Boot::CatchUp enqueued a sync
    # (its cutoff had passed) while GET /api/v1/sync reported stale: false
    # (Monday-strictly-before is Friday). One answer now.
    test "Monday 23:00 ET with the cache current through Friday is stale" do
      friday = Date.new(2026, 7, 17)
      seed_calendar_through(friday)

      result = Prices::Freshness.call(now: et(2026, 7, 20, 23))

      assert_equal Date.new(2026, 7, 20), result.expected_session, "Monday's close is due by 23:00"
      assert result.stale, "the UI must not say 'current' while the boot check is fetching"
    end

    # -- weekend handling ----------------------------------------------------

    test "on a Monday morning, Friday's close is current" do
      friday = Date.new(2026, 7, 17)
      seed_calendar_through(friday)

      assert_not Prices::Freshness.call(now: et(2026, 7, 20, 9)).stale,
        "the weekend produced no closes; Friday IS the newest expected trading day"
    end

    test "on a Sunday, Friday's close is current" do
      friday = Date.new(2026, 7, 17)
      seed_calendar_through(friday)

      assert_not Prices::Freshness.call(now: et(2026, 7, 19, 12)).stale
    end

    test "on a Saturday night the weekend is still walked back to Friday" do
      friday = Date.new(2026, 7, 17)
      seed_calendar_through(friday)

      result = Prices::Freshness.call(now: et(2026, 7, 18, 23))

      assert_equal friday, result.expected_session,
        "past 22:00 on a Saturday, 'today' is a Saturday — there is no Saturday session"
      assert_not result.stale
    end

    test "on a Saturday, Thursday's close is NOT current — Friday's is missing" do
      seed_calendar_through(Date.new(2026, 7, 16)) # Thursday

      assert Prices::Freshness.call(now: et(2026, 7, 18, 12)).stale
    end

    # -- instruments_behind: the signal a MAX cannot give (issue #59) ---------

    test "one lagging instrument is counted even though the cache as a whole is current" do
      seed_calendar_through(TUESDAY) # SPY, referenced, current
      aapl = create_instrument(symbol: "AAPL")
      refer_to(aapl)
      aapl.update!(latest_price_on: Date.new(2026, 7, 17)) # its fetch failed on Monday

      result = Prices::Freshness.call(now: MORNING)

      assert_not result.stale, "SPY holds the MAX up — this is exactly what `stale` cannot see"
      assert_equal 1, result.instruments_behind
      assert result.behind?, "a boot must still retry the symbol whose fetch failed"
    end

    test "a referenced instrument that has never been priced counts as behind" do
      seed_calendar_through(TUESDAY)
      refer_to(create_instrument(symbol: "AAPL")) # latest_price_on nil

      assert_equal 1, Prices::Freshness.call(now: MORNING).instruments_behind
    end

    test "an UNreferenced laggard is not counted" do
      seed_calendar_through(TUESDAY)
      create_instrument(symbol: "ZZZZ").update!(latest_price_on: Date.new(2020, 1, 1))

      assert_equal 0, Prices::Freshness.call(now: MORNING).instruments_behind,
        "nothing syncs it, so it can never catch up and must not nag forever"
    end

    test "every referenced instrument behind means every one of them is counted" do
      seed_calendar_through(Date.new(2026, 7, 15))
      %w[AAPL MSFT].each { |s| refer_to(create_instrument(symbol: s)) }

      result = Prices::Freshness.call(now: MORNING)

      assert result.stale
      assert_equal 3, result.instruments_behind, "SPY plus the two holdings"
    end

    test "the count is one aggregate query, not one per instrument" do
      seed_calendar_through(TUESDAY)
      5.times { |i| refer_to(create_instrument(symbol: "SYM#{i}")) }

      queries = count_queries { Prices::Freshness.call(now: MORNING, check_pending: false) }

      assert_operator queries, :<=, 2,
        "expected the calendar max + one aggregate; got #{queries} queries"
    end

    # -- the pending lease ---------------------------------------------------

    test "a held sync claim surfaces as pending with its claim time" do
      seed_calendar_through(TUESDAY)
      triggered = Prices::SyncTrigger.call(source: "test")

      result = Prices::Freshness.call(now: MORNING)

      assert result.pending?
      assert_equal triggered.requested_at.iso8601, result.pending_since.iso8601,
        "the snapshot reports the SAME claim time POST /api/v1/sync returned"
    end

    test "no claim means pending_since is nil" do
      assert_nil Prices::Freshness.call(now: MORNING).pending_since
    end

    test "a released claim stops being pending" do
      Prices::SyncTrigger.call(source: "test")
      Rails.cache.delete(Prices::SyncTrigger::CLAIM_KEY)

      assert_not Prices::Freshness.call(now: MORNING).pending?
    end

    # Boot::CatchUp reaches this class from an initializer, where the CACHE
    # database may not be migrated. check_pending: false must not touch it.
    test "check_pending: false never reads the cache store" do
      Prices::SyncTrigger.call(source: "test") # a live claim the snapshot must ignore

      result = nil
      no_cache_reads do
        assert_nothing_raised { result = Prices::Freshness.call(now: MORNING, check_pending: false) }
      end

      assert_nil result.pending_since
      assert_not result.pending?
    end

    # -- shape ---------------------------------------------------------------

    test "the result struct is frozen" do
      assert Prices::Freshness.call(now: MORNING).frozen?
    end

    test "a naive UTC clock is coerced to America/New_York before the cutoff is applied" do
      seed_calendar_through(TUESDAY)

      # 2026-07-23 01:00 UTC is 2026-07-22 21:00 EDT — still before the drop.
      assert_equal TUESDAY, Prices::Freshness.call(now: Time.utc(2026, 7, 23, 1)).expected_session
      # 2026-07-23 02:00 UTC is 2026-07-22 22:00 EDT — after it.
      assert_equal WEDNESDAY, Prices::Freshness.call(now: Time.utc(2026, 7, 23, 2)).expected_session
    end

    private

    def et(...) = self.class.et(...)

    # Seed the SPY calendar through `date` AND advance the instrument bounds the
    # way Prices::SeriesWriter does (seed_prices writes daily_prices only).
    def seed_calendar_through(date)
      spy = create_trading_days(date - 20.days, date)
      spy.update!(latest_price_on: date)
      Benchmark.find_or_create_by!(instrument: spy) { |b| b.name = "S&P 500" }
      spy
    end

    # Make an instrument "referenced" the cheapest legitimate way — a benchmark
    # is the third arm of Instrument.referenced and needs no portfolio, no
    # directory listing and no position replay.
    def refer_to(instrument)
      Benchmark.create!(instrument: instrument, name: "Bench #{instrument.symbol}")
    end

    # Fail loudly if anything inside the block reads the cache store. There is
    # no minitest/mock in this bundle, so subscribe to the instrumentation the
    # store already emits.
    def no_cache_reads
      reads = []
      counter = ->(_n, _s, _f, _i, payload) { reads << payload[:key] }
      ActiveSupport::Notifications.subscribed(counter, "cache_read.active_support") { yield }
      assert_empty reads, "boot-path freshness must not touch the cache store"
    end
  end
end
