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
    # A provisioned symbol directory is the STEADY state — every boot after the
    # first has one — so it is the default here and the empty case is set up
    # explicitly by the issue #72 tests below. Without this, every test in this
    # file would also assert on a Directory::ImportJob enqueue.
    ListedInstrument.create!(symbol: "AAPL", exchange: "NASDAQ", asset_type: "Stock", currency: "USD")
    # Creating an instrument fires its first-reference backfill/metadata jobs
    # (after_commit callbacks DO run in transactional tests) — start clean so
    # every count below is about the boot catch-up and nothing else.
    clear_enqueued_jobs
  end

  # Puts the deploy back into its first-boot state.
  def unprovisioned_directory!
    ListedInstrument.delete_all
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

  # issue #59: the gap #55 believed its cached-vs-calendar signal covered and
  # did not. SPY is current and referenced, so it holds max(latest_price_on) at
  # the reference day and `stale` is FALSE — yet AAPL's fetch failed. The boot
  # must still retry it, which only the per-instrument count can decide.
  test "one referenced instrument lagging behind a current SPY still enqueues a sync" do
    spy = Instrument.find_by!(symbol: "SPY")
    Benchmark.create!(instrument: spy, name: "S&P 500 test") # SPY is referenced in a real install
    spy.update_columns(latest_price_on: LAST_TRADING_DAY)
    priced_through(@aapl, LAST_TRADING_DAY - 3) # its fetch failed three sessions ago
    clear_enqueued_jobs

    result = Boot::CatchUp.call

    assert_equal LAST_TRADING_DAY, result.latest_price_on, "the MAX is current — `stale` cannot see this"
    assert_equal 1, result.instruments_behind
    assert_equal [ "Prices::DailySyncJob" ], result.enqueued
    assert_enqueued_jobs 1, only: Prices::DailySyncJob
  end

  # The boot path must never touch the cache store: the sync-claim lease lives
  # in a SEPARATE database (Solid Cache) that can be unmigrated on a first boot.
  test "the boot check never reads the sync-claim lease" do
    priced_through(@aapl, LAST_TRADING_DAY - 1)
    Prices::SyncTrigger.call(source: "test") # a live claim it must not consult
    clear_enqueued_jobs

    reads = []
    counter = ->(_n, _s, _f, _i, payload) { reads << payload[:key] }
    result = nil
    ActiveSupport::Notifications.subscribed(counter, "cache_read.active_support") do
      result = Boot::CatchUp.call
    end

    assert_empty reads, "a boot-time cache read is a boot-time dependency on the cache database"
    assert_equal :ok, result.status
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
  # --- issue #72: a fresh deploy must not reject every symbol for a week ---
  #
  # A clean production volume starts with listed_instruments EMPTY and the
  # directory import only runs weekly, so until it does, DirectoryResolver has
  # nothing to validate against and every typed symbol 422s. Measured on a real
  # clean deploy during #54's gate.

  test "an EMPTY directory enqueues the import so a fresh deploy can validate symbols" do
    priced_through(@aapl, LAST_TRADING_DAY)
    unprovisioned_directory!
    assert_equal 0, ListedInstrument.count, "precondition: fresh deploy"

    result = Boot::CatchUp.call

    assert_includes result.enqueued, "Directory::ImportJob"
    assert_enqueued_jobs 1, only: Directory::ImportJob
  end

  # The anti-storm guard. Boot::CatchUp deliberately bypasses SyncTrigger's
  # 10-minute lease, so anything added here runs on EVERY boot unless it guards
  # itself — and this one is a ~106,300-row download.
  test "a POPULATED directory enqueues no import, so repeated boots do no work" do
    priced_through(@aapl, LAST_TRADING_DAY)   # setup already provisioned the directory

    3.times { Boot::CatchUp.call }

    assert_no_enqueued_jobs only: Directory::ImportJob
  end

  # This slot used to hold "a restart while the first import is still queued
  # does not enqueue a second", guarding a SolidQueue::Job lookup. Both the
  # guard and the test are gone: the test passed for the WRONG reason. Reading
  # SolidQueue::Job raises in the test environment (the queue database is not
  # migrated), and in Postgres a failed statement ABORTS the surrounding
  # transaction — so the second Boot::CatchUp.call errored out entirely and
  # enqueued nothing at all, including the price sync. The assertion saw
  # "no second import" and passed. See the note on #directory_unprovisioned?.
  #
  # What replaces it is the honest property: a restart during provisioning DOES
  # enqueue again, and that is safe because the import is idempotent.
  test "a restart during provisioning enqueues again — bounded and idempotent, not suppressed" do
    priced_through(@aapl, LAST_TRADING_DAY)
    unprovisioned_directory!

    first = Boot::CatchUp.call
    second = Boot::CatchUp.call

    assert_includes first.enqueued, "Directory::ImportJob"
    assert_includes second.enqueued, "Directory::ImportJob",
      "an empty directory is still unprovisioned, so the next boot must try again"
    # Both boots ran fully — the point the vacuous version missed.
    assert_equal :ok, second.status
    assert_enqueued_jobs 2, only: Directory::ImportJob
  end

  test "a missing listed_instruments table is schema-not-loaded, not a crash" do
    execute_sql("ALTER TABLE listed_instruments RENAME TO listed_instruments_not_yet_migrated")

    result = nil
    assert_nothing_raised { result = Boot::CatchUp.call }

    assert_equal :database_not_ready, result.status
    assert_equal [ "listed_instruments" ], result.details[:missing_tables]
    assert_empty result.enqueued
    assert_no_enqueued_jobs
  end
end
