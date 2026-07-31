module Boot
  # Catch-up-on-boot (issue #55, docs/PLAN.md § Deployment).
  #
  # The box this app runs on will not reliably be awake at 22:00 ET, so the
  # Solid Queue nightly schedule alone cannot be trusted. On every app start we
  # ask two cheap questions and enqueue at most one job each:
  #
  #   1. Is any ACTIVE instrument (Instrument.referenced — anything a
  #      transaction, recurring rule or benchmark points at) behind the last
  #      expected session? Then enqueue Prices::DailySyncJob. The sync only
  #      ever fetches the delta since each instrument's last cached date, so a
  #      redundant run is a cheap no-op.
  #   2. Does any active recurring rule have next_run_on <= today (ET)? Then
  #      enqueue Recurring::MaterializeDueJob, whose materializer loops through
  #      every missed slot in one pass.
  #
  # Both jobs are idempotent by construction, which is what makes running them
  # opportunistically at boot safe.
  #
  # NOTHING HERE MAY RAISE. This runs from an initializer, so an exception is a
  # boot failure: the very first `docker compose up` reaches it with no database
  # at all, and `bin/rails db:prepare` reaches it with an empty one. Every path
  # is guarded and every failure degrades to "log it and skip".
  #
  # Whether this process should run at all is Boot::Eligibility's decision, not
  # this class's — .call is the pure, repeatable data check, so tests can drive
  # it directly in the test environment.
  #
  # WHAT "BEHIND" MEANS IS NOT DECIDED HERE (see Prices::Freshness). This class used to
  # compute its own reference day, which drifted from the one GET /api/v1/sync
  # reported: on a Monday at 23:00 ET with the cache current through Friday it
  # enqueued a sync while the API said `stale: false`. The single definition now
  # lives in Prices::Freshness, which both this and the API consume; the only
  # decision left here is what to DO about it.
  class CatchUp
    LOG_TAG = "[Boot::CatchUp]".freeze

    # Every table the two checks touch, including the three the
    # Instrument.referenced subqueries reach into. A missing one means the
    # schema is not loaded yet (first boot, or a boot racing db:prepare).
    #
    # This list also bounds what Prices::Freshness is allowed to query — see the
    # BOOT SAFETY note there before adding a table to either side.
    REQUIRED_TABLES = %w[
      instruments
      daily_prices
      transactions
      recurring_transactions
      benchmarks
      listed_instruments
    ].freeze

    # status: :ok | :database_not_ready | :error
    #
    # reference_day is Prices::Freshness#expected_session — the day whose closes
    # the staleness check demanded. Kept under this name because it is what the
    # boot log calls it.
    Result = Struct.new(:status, :enqueued, :latest_price_on, :last_trading_day,
                        :reference_day, :instruments_behind, :recurring_due,
                        :details, keyword_init: true)

    def self.call = new.call

    def call
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        missing = REQUIRED_TABLES - connection.data_sources
        next database_not_ready(missing) if missing.any?

        check_and_enqueue
      end
    rescue StandardError => e
      # ActiveRecord::NoDatabaseError / ConnectionNotEstablished (no database
      # yet), and anything perform_later can raise when the Solid Queue database
      # is not migrated either.
      log(:warn, "skipped: #{e.class}: #{e.message}")
      finish(Result.new(status: :error, enqueued: [], details: { error: e.class.name }))
    end

    private

    def check_and_enqueue
      # check_pending: false — the sync-claim lease lives in the CACHE store,
      # a separate database that may be unmigrated on a first boot. Boot must
      # not read it, and the answer would not change what we do: the enqueue is
      # already idempotent and the nightly schedule bypasses the lease too.
      freshness = Prices::Freshness.call(check_pending: false)
      due = recurring_due?
      directory = directory_unprovisioned?

      enqueued = []
      enqueued << enqueue(Directory::ImportJob) if directory
      # Freshness#behind?, not #stale — see the note below.
      enqueued << enqueue(Prices::DailySyncJob) if freshness.behind?
      enqueued << enqueue(Recurring::MaterializeDueJob) if due

      log(:info, "prices: latest=#{freshness.latest_price_on || 'none'} " \
                 "last_trading_day=#{freshness.last_trading_day || 'none'} " \
                 "reference=#{freshness.expected_session} stale=#{freshness.stale} " \
                 "instruments_behind=#{freshness.instruments_behind}; " \
                 "recurring_due=#{due}; directory_unprovisioned=#{directory}; " \
                 "enqueued=#{enqueued.presence&.join(', ') || 'nothing'}")

      finish(Result.new(status: :ok, enqueued: enqueued,
                        latest_price_on: freshness.latest_price_on,
                        last_trading_day: freshness.last_trading_day,
                        reference_day: freshness.expected_session,
                        instruments_behind: freshness.instruments_behind,
                        recurring_due: due))
    end

    # WHY Freshness#behind? AND NOT Freshness#stale. Same predicate, same
    # expected session; this is the enqueue decision rather than the display
    # one, and the two differ in both directions:
    #
    # - `stale` is a MAX comparison, so it cannot see ONE referenced instrument
    #   whose fetch failed while SPY's succeeded — SPY is always in the set and
    #   holds the max up. (#55 claimed its cached-vs-calendar signal caught
    #   this. It did not, and could not: both sides of that comparison were
    #   maxima over the same cache.) `behind?` counts individual laggards, so a
    #   boot after a partial fan-out failure retries it — one idempotent delta
    #   fetch, the same work the nightly run would do anyway.
    # - On an empty database `stale` is true (the UI must say "never synced")
    #   but `behind?` is 0: nothing is referenced, so there is nothing to fetch
    #   and enqueueing a fan-out over zero instruments is pure noise.

    # A fresh deploy starts with listed_instruments EMPTY, and the directory
    # import is only scheduled weekly (Sundays 03:00). Until it runs,
    # Instruments::DirectoryResolver has nothing to validate against, so EVERY
    # symbol the user types is rejected with "is not a recognized US-exchange
    # symbol" — an error that blames their input for an unprovisioned cache.
    # Measured on a real clean deploy during #54's gate (issue #72).
    #
    # EMPTY, not stale. Deliberately the narrowest possible trigger:
    #
    # - An empty table is unambiguous — it can only mean "never provisioned",
    #   so there is no judgement call and no threshold to tune. Refreshing a
    #   populated-but-old directory stays the weekly schedule's job.
    # - It is self-limiting. One successful import makes this false forever, so
    #   the steady state is zero work per boot — which matters because
    #   Boot::CatchUp deliberately bypasses SyncTrigger's 10-minute lease, so
    #   anything added here runs on EVERY boot unless it guards itself.
    # - The file is a ~106,300-row keyless download: free in provider quota,
    #   not free in time or DB writes. A crash-looping container must not
    #   re-download it on every restart, which is why the already-enqueued
    #   check below exists as well.
    #
    # `none?` compiles to SELECT 1 ... LIMIT 1, so this costs an index probe.
    # DELIBERATELY NO "is one already queued?" CHECK. The obvious refinement is
    # to skip the enqueue while an import is queued-but-unrun, so a restart
    # during provisioning does not stack duplicates. It was implemented, and
    # removed, for two reasons found by probing it:
    #
    #   1. It cannot be tested here. Reading SolidQueue::Job touches the QUEUE
    #      database, which the test environment does not migrate, so the query
    #      always raises and the guard's real branch never runs under test.
    #   2. Worse, that raise POISONS the surrounding transaction. Postgres
    #      aborts a transaction after a failed statement, so in the
    #      transactional suite the NEXT Boot::CatchUp.call failed outright and
    #      returned status: :error with nothing enqueued. The "a restart does
    #      not enqueue a second" test passed because the whole call had errored,
    #      not because the guard worked - a vacuous pass hiding a real hazard.
    #
    # What is lost is bounded and self-correcting: a restart inside the
    # provisioning window may enqueue a second import. Directory::ImportJob is
    # idempotent (upsert_all on (symbol, exchange), preserving enriched names
    # via COALESCE since #63) and its sanity guard refuses an implausibly small
    # file, so a duplicate run costs one redundant download and changes no data.
    # One success makes this predicate false forever.
    def directory_unprovisioned? = ListedInstrument.none?

    # Mirrors Recurring::MaterializeDueJob's own selection exactly (and hits the
    # partial index on next_run_on WHERE active).
    def recurring_due?
      RecurringTransaction.where(active: true)
                          .where(next_run_on: ..Trading::Calendar.today)
                          .exists?
    end

    def enqueue(job_class)
      job_class.perform_later
      job_class.name
    end

    def database_not_ready(missing)
      log(:info, "skipped: schema not loaded (missing #{missing.join(', ')})")
      finish(Result.new(status: :database_not_ready, enqueued: [], details: { missing_tables: missing }))
    end

    def finish(result) = result.freeze

    def log(level, message) = Rails.logger.public_send(level, "#{LOG_TAG} #{message}")
  end
end
