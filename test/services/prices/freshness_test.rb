require "test_helper"

module Prices
  # issue #56: the global price-cache freshness snapshot behind GET /api/v1/sync.
  class FreshnessTest < ActiveSupport::TestCase
    include DomainTestHelper

    # A Wednesday, so "the most recent weekday strictly before today" is an
    # unremarkable Tuesday and no weekend logic is implicitly under test.
    WEDNESDAY = Date.new(2026, 7, 22).freeze
    TUESDAY   = Date.new(2026, 7, 21).freeze

    # -- the fresh-database null case ---------------------------------------

    test "an empty database reports nulls and is stale" do
      result = Prices::Freshness.call(today: WEDNESDAY)

      assert_nil result.latest_price_on, "nothing cached yet"
      assert_nil result.last_trading_day, "no calendar yet"
      assert result.stale, "a database with no prices must tell the user to sync"
      assert_not result.pending?
      assert_nil result.pending_since
    end

    test "an empty database still serializes, with nulls the UI can render" do
      json = SyncStatusSerializer.new(Prices::Freshness.call(today: WEDNESDAY)).as_json

      assert_nil json.dig(:sync, :latest_price_on)
      assert_nil json.dig(:sync, :last_trading_day)
      assert_nil json.dig(:sync, :requested_at)
      assert_equal true, json.dig(:sync, :stale)
      assert_equal false, json.dig(:sync, :pending)
    end

    # -- the populated case --------------------------------------------------

    test "a cache current through yesterday is NOT stale" do
      seed_calendar_through(TUESDAY)

      result = Prices::Freshness.call(today: WEDNESDAY)

      assert_equal TUESDAY, result.latest_price_on
      assert_equal TUESDAY, result.last_trading_day
      assert_not result.stale, "the newest expected close has landed"
    end

    test "latest_price_on is the MAX across referenced instruments" do
      seed_calendar_through(TUESDAY)
      aapl = create_instrument(symbol: "AAPL")
      refer_to(aapl)
      aapl.update!(latest_price_on: Date.new(2026, 7, 20)) # a laggard

      result = Prices::Freshness.call(today: WEDNESDAY)

      assert_equal TUESDAY, result.latest_price_on,
        "MAX, not MIN — docs/PLAN.md words the boot catch-up in terms of max(latest_price_on)"
    end

    test "an UNreferenced instrument is ignored, however current it is" do
      seed_calendar_through(TUESDAY)
      create_instrument(symbol: "ZZZZ").update!(latest_price_on: Date.new(2030, 1, 1))

      assert_equal TUESDAY, Prices::Freshness.call(today: WEDNESDAY).latest_price_on,
        "the sync only fans out over referenced instruments, so only they define freshness"
    end

    # -- the stale branch ----------------------------------------------------

    test "a cache a week behind IS stale" do
      seed_calendar_through(Date.new(2026, 7, 15))

      result = Prices::Freshness.call(today: WEDNESDAY)

      assert result.stale, "the box was asleep; the newest expected close never landed"
      assert_equal Date.new(2026, 7, 15), result.last_trading_day
    end

    test "one day behind is already stale" do
      seed_calendar_through(Date.new(2026, 7, 20)) # Monday, expected is Tuesday

      assert Prices::Freshness.call(today: WEDNESDAY).stale
    end

    # -- weekend handling ----------------------------------------------------

    test "on a Monday, Friday's close is current" do
      friday = Date.new(2026, 7, 17)
      monday = Date.new(2026, 7, 20)
      seed_calendar_through(friday)

      assert_not Prices::Freshness.call(today: monday).stale,
        "the weekend produced no closes; Friday IS the newest expected trading day"
    end

    test "on a Sunday, Friday's close is current" do
      friday = Date.new(2026, 7, 17)
      sunday = Date.new(2026, 7, 19)
      seed_calendar_through(friday)

      assert_not Prices::Freshness.call(today: sunday).stale
    end

    test "on a Saturday, Thursday's close is NOT current — Friday's is missing" do
      seed_calendar_through(Date.new(2026, 7, 16)) # Thursday
      saturday = Date.new(2026, 7, 18)

      assert Prices::Freshness.call(today: saturday).stale
    end

    # -- the pending lease ---------------------------------------------------

    test "a held sync claim surfaces as pending with its claim time" do
      seed_calendar_through(TUESDAY)
      triggered = Prices::SyncTrigger.call(source: "test")

      result = Prices::Freshness.call(today: WEDNESDAY)

      assert result.pending?
      assert_equal triggered.requested_at.iso8601, result.pending_since.iso8601,
        "the snapshot reports the SAME claim time POST /api/v1/sync returned"
    end

    test "no claim means pending_since is nil" do
      assert_nil Prices::Freshness.call(today: WEDNESDAY).pending_since
    end

    test "a released claim stops being pending" do
      Prices::SyncTrigger.call(source: "test")
      Rails.cache.delete(Prices::SyncTrigger::CLAIM_KEY)

      assert_not Prices::Freshness.call(today: WEDNESDAY).pending?
    end

    test "the result struct is frozen" do
      assert Prices::Freshness.call(today: WEDNESDAY).frozen?
    end

    private

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
  end
end
