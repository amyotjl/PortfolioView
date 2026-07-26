module Boot
  # Catch-up-on-boot (issue #55, docs/PLAN.md § Deployment).
  #
  # The box this app runs on will not reliably be awake at 22:00 ET, so the
  # Solid Queue nightly schedule alone cannot be trusted. On every app start we
  # ask two cheap questions and enqueue at most one job each:
  #
  #   1. Is max(latest_price_on) across ACTIVE instruments (Instrument.referenced
  #      — anything a transaction, recurring rule or benchmark points at) behind
  #      the last session? Then enqueue Prices::DailySyncJob. The sync only
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
  class CatchUp
    LOG_TAG = "[Boot::CatchUp]".freeze

    # Every table the two checks touch, including the three the
    # Instrument.referenced subqueries reach into. A missing one means the
    # schema is not loaded yet (first boot, or a boot racing db:prepare).
    REQUIRED_TABLES = %w[
      instruments
      daily_prices
      transactions
      recurring_transactions
      benchmarks
    ].freeze

    # US EOD data has landed by this hour (ET) — the same slot config/recurring.yml
    # schedules the nightly sync in. Before it, the current day's close is not
    # yet expected and its absence is not staleness.
    DATA_LANDS_AT_HOUR = 22

    # status: :ok | :database_not_ready | :error
    Result = Struct.new(:status, :enqueued, :latest_price_on, :last_trading_day,
                        :reference_day, :recurring_due, :details, keyword_init: true)

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
      enqueued = []
      stale = prices_stale?
      due = recurring_due?

      enqueued << enqueue(Prices::DailySyncJob) if stale
      enqueued << enqueue(Recurring::MaterializeDueJob) if due

      log(:info, "prices: latest=#{@latest_price_on || 'none'} " \
                 "last_trading_day=#{@last_trading_day || 'none'} " \
                 "reference=#{@reference_day || 'none'} stale=#{stale}; " \
                 "recurring_due=#{due}; enqueued=#{enqueued.presence&.join(', ') || 'nothing'}")

      finish(Result.new(status: :ok, enqueued: enqueued, latest_price_on: @latest_price_on,
                        last_trading_day: @last_trading_day, reference_day: @reference_day,
                        recurring_due: due))
    end

    # An instrument nothing references is deliberately never synced (it burns
    # provider quota for no one), so its stale prices must not trigger a boot
    # sync either — the same Instrument.referenced scope the nightly fan-out
    # uses defines "active" here.
    #
    # The reference day is the LATER of two signals, because neither alone is
    # sufficient:
    #
    # - Trading::Calendar.last_day (the newest day in the cache) catches one
    #   instrument lagging behind the rest — its fetch failed while SPY's
    #   succeeded. This is the comparison docs/PLAN.md § Deployment names.
    # - last_expected_session catches the case that motivates the whole feature:
    #   the box was ASLEEP through one or more sessions. On its own the cached
    #   comparison cannot see that, and would make this initializer dead code —
    #   SPY is a seeded benchmark, so it is always `referenced`, and
    #   Prices::SeriesWriter keeps its latest_price_on equal to the newest SPY
    #   price row, which IS Calendar.last_day. max(latest_price_on) is therefore
    #   never below it in a real install. See the report on issue #55.
    #
    # A nil latest_price_on counts as behind: a referenced instrument with no
    # cached prices is exactly the "we are behind" state a fresh install boots
    # into.
    def prices_stale?
      return false unless Instrument.referenced.exists?

      @latest_price_on = Instrument.referenced.maximum(:latest_price_on)
      @last_trading_day = Trading::Calendar.last_day
      @reference_day = [ @last_trading_day, last_expected_session ].compact.max

      @latest_price_on.nil? || @latest_price_on < @reference_day
    end

    # The most recent day whose closes should already be cached.
    #
    # Weekday-only, and deliberately NOT a claim about the trading calendar:
    # Trading::Calendar is cache-derived (a trading day is a day SPY has a row
    # for), so it cannot answer "has a session happened that we never fetched?"
    # — the question this whole initializer exists to ask. Holidays are not
    # modelled here for the same reason they are not modelled anywhere else in
    # this app: a holiday boot enqueues one fan-out whose delta fetches find
    # nothing, exactly like the nightly 7-day schedule already does. The weekend
    # clamp mirrors the gate Prices::DailySyncJob applies to itself, so a
    # Saturday boot with the week's data cached stays silent.
    #
    # NEVER use this for domain math. Trading::Calendar remains the only
    # calendar any money calculation may consult.
    def last_expected_session
      now = ActiveSupport::TimeZone[Trading::Calendar::TIME_ZONE].now
      date = now.hour < DATA_LANDS_AT_HOUR ? now.to_date - 1 : now.to_date
      date -= 1 while date.saturday? || date.sunday?
      date
    end

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
