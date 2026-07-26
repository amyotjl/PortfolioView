module Prices
  # The ONE way anything on-demand asks for a price sync (docs/PLAN.md
  # § Deployment: the Settings "Sync now" button and the token-guarded
  # `POST /api/internal/jobs/daily_sync` cron hook).
  #
  # Both entry points funnel through here so they share one dedupe window and
  # cannot stack duplicate fan-outs against each other.
  #
  # DEDUPE — a single-writer claim lease in the cache store (backlog #052 /
  # issue #56):
  #
  #   * `cache.write(CLAIM_KEY, ..., unless_exist: true)` is ATOMIC in both
  #     stores this app uses — MemoryStore writes under its monitor, and
  #     SolidCache's `unless_exist` path takes a row lock
  #     (`entry_lock_and_write`). It returns false when the key already holds a
  #     live entry, so exactly one concurrent caller can win the claim.
  #   * The winner enqueues Prices::DailySyncJob. Every other caller gets a
  #     no-op result carrying the WINNER's timestamp, and enqueues nothing.
  #   * Nothing releases the claim early: it simply expires after LEASE. That
  #     makes this a strict debounce ("at most one on-demand sync per LEASE"),
  #     not a liveness lock — so a job that dies, or a worker that never picks
  #     it up, can never wedge the trigger permanently. Worst case a user waits
  #     out the lease.
  #
  # Deliberately NOT a Solid Queue pendency query: the whole point is that this
  # is checkable and testable under any ActiveJob adapter (the suite runs the
  # :test adapter, which never touches the solid_queue tables), and the same
  # code path is what production exercises.
  #
  # The nightly `config/recurring.yml` schedule still enqueues DailySyncJob
  # directly and deliberately bypasses the lease — a scheduled 22:00 ET sync is
  # the baseline the on-demand path is layered on top of, and a user click at
  # 21:59 must not cancel the night's run. The fan-out itself is idempotent
  # (delta fetch from `latest_price_on` INCLUSIVE, `limits_concurrency`
  # serialized, budget-capped), so an overlap costs re-checking cached dates,
  # never duplicate or corrupted rows.
  class SyncTrigger
    CLAIM_KEY = "prices/daily_sync/claim".freeze

    # Long enough that a user mashing "Sync now" (or a cron misfire) collapses
    # into one run; short enough that a dead job doesn't lock anyone out for
    # long. Read by the API layer only for documentation, never for branching.
    LEASE = 10.minutes

    # :enqueued        — this call won the claim and enqueued DailySyncJob.
    # :already_pending — a claim from `requested_at` is still live; nothing enqueued.
    Result = Data.define(:status, :requested_at, :job_id) do
      def enqueued? = status == :enqueued
      def already_pending? = status == :already_pending
    end

    def self.call(...) = new(...).call

    # `source` is for the log line only (which entry point asked) — it never
    # affects behavior, so the two callers cannot drift apart.
    def initialize(source:, cache: Rails.cache, lease: LEASE, now: Time.current)
      @source = source.to_s
      @cache = cache
      @lease = lease
      @now = now.utc
    end

    def call
      if claim!
        job = Prices::DailySyncJob.perform_later
        Rails.logger.info("[#{self.class.name}] #{source}: enqueued DailySyncJob #{job.job_id}, claim held #{lease.inspect}")
        Result.new(status: :enqueued, requested_at: now, job_id: job.job_id).freeze
      else
        claimed = claimed_at
        Rails.logger.info("[#{self.class.name}] #{source}: no-op, a sync claimed at #{claimed.iso8601} is still pending")
        Result.new(status: :already_pending, requested_at: claimed, job_id: nil).freeze
      end
    end

    private

    attr_reader :source, :cache, :lease, :now

    def claim!
      cache.write(CLAIM_KEY, now.iso8601, unless_exist: true, expires_in: lease)
    end

    # The winning claim's timestamp. Falls back to `now` if the entry expired
    # in the sliver between the failed write and this read — a cosmetic detail
    # of the reported time, never of whether work was enqueued.
    def claimed_at
      raw = cache.read(CLAIM_KEY)
      raw.present? ? Time.iso8601(raw).utc : now
    rescue ArgumentError
      now
    end
  end
end
