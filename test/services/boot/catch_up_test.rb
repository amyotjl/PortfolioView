require "test_helper"

class Boot::CatchUpTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include DomainTestHelper

  # The synthetic trading calendar's last day (a Tuesday).
  LAST_TRADING_DAY = Date.new(2026, 3, 31)
  # 22:00 ET on that day: the evening's closes are expected, so the reference
  # day the staleness check compares against is LAST_TRADING_DAY itself.
  BOOT_INSTANT = Time.utc(2026, 4, 1, 2, 0)

  setup do
    travel_to BOOT_INSTANT
    @portfolio = create_portfolio
    @aapl = create_instrument(symbol: "AAPL")
    create_trading_days(Date.new(2026, 3, 23), LAST_TRADING_DAY)
    buy!(@portfolio, @aapl, on: Date.new(2026, 3, 23), shares: "10", price: "100")
    # Creating an instrument fires its first-reference backfill/metadata jobs
    # (after_commit callbacks DO run in transactional tests) — start clean so
    # every count below is about the boot catch-up and nothing else.
    clear_enqueued_jobs
  end

  # --- criterion 1: stale prices enqueue exactly one DailySyncJob ---

  test "enqueues DailySyncJob exactly once when the newest cached price is behind the last trading day" do
    priced_through(@aapl, LAST_TRADING_DAY - 1)

    result = Boot::CatchUp.call

    assert_equal :ok, result.status
    assert_equal [ "Prices::DailySyncJob" ], result.enqueued
    assert_equal LAST_TRADING_DAY - 1, result.latest_price_on
    assert_equal LAST_TRADING_DAY, result.last_trading_day
    assert_enqueued_jobs 1, only: Prices::DailySyncJob
    assert_enqueued_with(job: Prices::DailySyncJob, args: [])
  end

  # The case the whole feature exists for, and the one the cache-vs-cache
  # comparison alone cannot see: the box slept through two sessions, so the
  # cache is internally consistent (SPY's own rows define Calendar.last_day)
  # and still out of date.
  test "a cache that is current with itself is still behind after a missed session" do
    priced_through(@aapl, LAST_TRADING_DAY)
    assert_equal LAST_TRADING_DAY, Trading::Calendar.last_day, "precondition: nothing lags inside the cache"

    travel_to Time.utc(2026, 4, 4, 2, 0) do # Friday 2026-04-03, 22:00 in New York
      result = Boot::CatchUp.call

      assert_equal Date.new(2026, 4, 3), result.reference_day
      assert_equal [ "Prices::DailySyncJob" ], result.enqueued
    end

    assert_enqueued_jobs 1, only: Prices::DailySyncJob
  end

  test "a weekend boot with the week's closes already cached enqueues nothing" do
    create_trading_days(Date.new(2026, 4, 1), Date.new(2026, 4, 3))
    priced_through(@aapl, Date.new(2026, 4, 3))
    clear_enqueued_jobs

    travel_to Time.utc(2026, 4, 4, 20, 0) do # Saturday 2026-04-04, 16:00 in New York
      result = Boot::CatchUp.call

      assert_equal Date.new(2026, 4, 3), result.reference_day, "the weekend has no session of its own"
      assert_empty result.enqueued
    end

    assert_no_enqueued_jobs
  end

  test "the current day's close is not expected before the evening data lands" do
    priced_through(@aapl, LAST_TRADING_DAY)

    travel_to Time.utc(2026, 4, 1, 14, 0) do # Wednesday 2026-04-01, 10:00 in New York
      result = Boot::CatchUp.call

      assert_equal LAST_TRADING_DAY, result.reference_day
      assert_empty result.enqueued
    end

    assert_no_enqueued_jobs
  end

  test "a referenced instrument with no cached prices at all counts as behind" do
    assert_nil @aapl.reload.latest_price_on

    assert_equal [ "Prices::DailySyncJob" ], Boot::CatchUp.call.enqueued
    assert_enqueued_jobs 1, only: Prices::DailySyncJob
  end

  # --- criterion 2: fresh data enqueues nothing, cheaply ---

  test "a boot with fresh data enqueues nothing" do
    priced_through(@aapl, LAST_TRADING_DAY)

    result = Boot::CatchUp.call

    assert_equal :ok, result.status
    assert_empty result.enqueued
    assert_no_enqueued_jobs
  end

  # "Active" is Instrument.referenced — what a transaction, recurring rule or
  # benchmark points at. Because the check is a MAX, widening the scope can only
  # make the cache look FRESHER than it is, so the discriminating case is a
  # fresh orphan next to a stale holding (a stale orphan proves nothing: it
  # cannot lower a maximum, and an earlier mutation probe passed against it).
  test "a fresh unreferenced instrument cannot mask a stale referenced one" do
    priced_through(@aapl, LAST_TRADING_DAY - 1) # held, and behind
    orphan = create_instrument(symbol: "MSFT")  # no transaction, rule or benchmark points at it
    priced_through(orphan, LAST_TRADING_DAY)    # up to date, and irrelevant
    clear_enqueued_jobs # MSFT's own first-reference backfill

    result = Boot::CatchUp.call

    assert_equal LAST_TRADING_DAY - 1, result.latest_price_on,
                 "max(latest_price_on) must be taken over referenced instruments only"
    assert_equal [ "Prices::DailySyncJob" ], result.enqueued
    assert_enqueued_jobs 1, only: Prices::DailySyncJob
  end

  test "a database with nothing referenced enqueues no sync at all" do
    Transaction.delete_all # now nothing points at AAPL, and SPY is only the calendar
    clear_enqueued_jobs

    result = Boot::CatchUp.call

    assert_empty result.enqueued
    assert_nil result.latest_price_on, "an unreferenced instrument must not even be measured"
    assert_no_enqueued_jobs
  end

  test "the check is cheap: a fresh-data boot is a handful of indexed reads" do
    priced_through(@aapl, LAST_TRADING_DAY)

    queries = count_queries { Boot::CatchUp.call }

    # table existence + referenced-exists + max(latest_price_on) + calendar
    # max(date) + due-rules exists. Nothing is written, nothing is loaded.
    assert_operator queries, :<=, 6, "boot catch-up issued #{queries} queries; it must stay a cheap check"
  end

  # --- criterion 3: due recurring rules enqueue the materializer ---

  test "enqueues MaterializeDueJob when an active rule is due today or earlier" do
    priced_through(@aapl, LAST_TRADING_DAY) # isolate the recurring path
    create_rule(next_run_on: Date.new(2026, 4, 1))

    travel_to Time.utc(2026, 4, 1, 16, 0) do # noon April 1st in New York
      result = Boot::CatchUp.call

      assert_equal [ "Recurring::MaterializeDueJob" ], result.enqueued
      assert result.recurring_due
    end

    assert_enqueued_jobs 1, only: Recurring::MaterializeDueJob
    assert_enqueued_with(job: Recurring::MaterializeDueJob, args: [])
  end

  test "leaves a future rule and an inactive due rule alone" do
    priced_through(@aapl, LAST_TRADING_DAY)
    create_rule(next_run_on: Date.new(2026, 12, 31))
    create_rule(next_run_on: Date.new(2026, 3, 1), active: false)

    travel_to Time.utc(2026, 4, 1, 16, 0) do
      result = Boot::CatchUp.call

      assert_empty result.enqueued
      assert_not result.recurring_due
    end

    assert_no_enqueued_jobs
  end

  test "enqueues each job exactly once when prices are stale and several rules are due" do
    priced_through(@aapl, Date.new(2026, 3, 30))
    create_rule(next_run_on: Date.new(2026, 4, 1))
    create_rule(next_run_on: Date.new(2026, 3, 31))

    travel_to Time.utc(2026, 4, 1, 16, 0) do
      assert_equal [ "Prices::DailySyncJob", "Recurring::MaterializeDueJob" ], Boot::CatchUp.call.enqueued
    end

    assert_enqueued_jobs 1, only: Prices::DailySyncJob
    assert_enqueued_jobs 1, only: Recurring::MaterializeDueJob
    assert_enqueued_jobs 2
  end

  # --- criterion 4: an unmigrated / absent database must not crash the boot ---

  test "is safe on an unmigrated database: schema missing, no crash, no jobs" do
    # A GENUINELY missing table, not a stub. Postgres DDL is transactional, so
    # the rename is undone with the test's own rollback.
    execute_sql("ALTER TABLE instruments RENAME TO instruments_not_yet_migrated")
    execute_sql("ALTER TABLE daily_prices RENAME TO daily_prices_not_yet_migrated")

    result = nil
    assert_nothing_raised { result = Boot::CatchUp.call }

    assert_equal :database_not_ready, result.status
    assert_equal %w[instruments daily_prices], result.details[:missing_tables]
    assert_empty result.enqueued
    assert_no_enqueued_jobs
  end

  test "is safe on a completely empty database: every required table missing" do
    Boot::CatchUp::REQUIRED_TABLES.each { |t| execute_sql("ALTER TABLE #{t} RENAME TO #{t}_not_yet_migrated") }

    result = nil
    assert_nothing_raised { result = Boot::CatchUp.call }

    assert_equal :database_not_ready, result.status
    assert_equal Boot::CatchUp::REQUIRED_TABLES, result.details[:missing_tables]
    assert_no_enqueued_jobs
  end

  test "is safe when the database itself does not exist" do
    # Simulated here, because a real NoDatabaseError needs a process boot with
    # the database dropped (done for real at the docker level — see the issue's
    # evidence). What this locks is that the failure is swallowed and reported,
    # never raised into boot.
    result = nil
    raising(ActiveRecord::Base.connection_pool, :with_connection,
            ActiveRecord::NoDatabaseError, 'database "app_production" does not exist') do
      assert_nothing_raised { result = Boot::CatchUp.call }
    end

    assert_equal :error, result.status
    assert_equal "ActiveRecord::NoDatabaseError", result.details[:error]
    assert_no_enqueued_jobs
  end

  test "a queue database that cannot accept the enqueue does not take the boot down" do
    priced_through(@aapl, LAST_TRADING_DAY - 1)

    result = nil
    raising(Prices::DailySyncJob, :perform_later,
            ActiveRecord::StatementInvalid, 'relation "solid_queue_jobs" does not exist') do
      assert_nothing_raised { result = Boot::CatchUp.call }
    end

    assert_equal :error, result.status
    assert_no_enqueued_jobs
  end

  test "returns a frozen result struct" do
    assert_predicate Boot::CatchUp.call, :frozen?
  end

  private

  def priced_through(instrument, date) = instrument.update_columns(latest_price_on: date)

  def execute_sql(sql) = ActiveRecord::Base.connection_pool.with_connection { |c| c.execute(sql) }

  # Minitest 6 dropped minitest/mock, and neither of these failures can be
  # staged for real inside a test transaction. Define the method on the
  # receiver's singleton and remove it afterwards, so the original (inherited or
  # instance) implementation is restored untouched.
  def raising(object, method, error_class, message)
    object.define_singleton_method(method) { |*| raise error_class, message }
    yield
  ensure
    object.singleton_class.send(:remove_method, method)
  end

  def create_rule(next_run_on:, active: true)
    rule = RecurringTransaction.create!(
      portfolio: @portfolio, instrument: @aapl,
      side: "buy", amount_type: "dollars", dollar_amount: "500.00",
      frequency: "monthly", anchor_on: Date.new(2026, 3, 31),
      next_run_on: Date.new(2099, 1, 1)
    )
    # A create clamps next_run_on forward to today; force the schedule the test needs.
    rule.update_columns(next_run_on: next_run_on, active: active)
    rule
  end
end
