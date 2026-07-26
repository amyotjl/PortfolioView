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
  # WHAT "BEHIND" MEANS IS NOT DECIDED HERE (issue #59). This class used to
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

      enqueued = []
      # Freshness#behind?, not #stale — see the note below.
      enqueued << enqueue(Prices::DailySyncJob) if freshness.behind?
      enqueued << enqueue(Recurring::MaterializeDueJob) if due

      log(:info, "prices: latest=#{freshness.latest_price_on || 'none'} " \
                 "last_trading_day=#{freshness.last_trading_day || 'none'} " \
                 "reference=#{freshness.expected_session} stale=#{freshness.stale} " \
                 "instruments_behind=#{freshness.instruments_behind}; " \
                 "recurring_due=#{due}; enqueued=#{enqueued.presence&.join(', ') || 'nothing'}")

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
