module Candles
  # Reusable Solid Cache wrapper for the candles endpoint (docs/PLAN.md
  # § Caching). Invalidation is purely by KEY ROTATION — nothing is ever
  # explicitly deleted; a stale entry simply becomes unreachable.
  #
  # Key scheme (frozen — single source of truth):
  #
  #   candles/v2/{pid}/{series_version}/{prices_version}/{from}/{to}/{benchmark_id}
  #
  # - series_version  bumps on any transaction/recurring mutation, backfill
  #   completion, or late-discovered historical split (wired on the models), so
  #   any change to the underlying trades rotates the key on the next read.
  # - prices_version  = max(latest_price_on) across ALL the portfolio's
  #   instruments (traded + recurring) AND the benchmark instrument — never just
  #   the benchmark's. A late-landing ticker fetch advances one instrument's
  #   latest_price_on, which rotates the key so no stale trading day survives.
  # - benchmark_id    distinguishes the benchmark-line variant from the bare
  #   candles variant ("none" when no benchmark is requested).
  #
  # Partial responses (meta[:partial] truthy) are NEVER written: a window that
  # is still settling (a held instrument-day with no obtainable price, or a
  # benchmark trade with no close on/after it yet) recomputes on every request
  # until it closes; a fully-priced closed window caches forever under its
  # natural key.
  class Cache
    # v2 (issue #80): the payload gained `cash` and three meta keys. series_version
    # alone does NOT cover a payload-shape change — an untracked portfolio's data
    # never changes, so its key would never rotate and a warm v1 entry (missing
    # the new keys) would keep being served to a client whose schema requires them.
    # Bump this on every shape change to the cached payload.
    VERSION = "v2".freeze
    NONE = "none".freeze

    def self.fetch(**kwargs, &block) = new(**kwargs).fetch(&block)

    def initialize(portfolio:, from:, to:, benchmark_id:)
      @portfolio = portfolio
      @from = from
      @to = to
      @benchmark_id = benchmark_id
    end

    # The frozen cache key for this (portfolio, version, window, benchmark).
    def key
      [
        "candles",
        VERSION,
        portfolio.id,
        portfolio.series_version,
        prices_version,
        from.iso8601,
        to.iso8601,
        benchmark_id || NONE
      ].join("/")
    end

    # Returns the cached payload on a hit (skipping the block entirely — no
    # valuation recompute); otherwise yields to compute it, caches it unless it
    # is partial, and returns it. The block MUST return a payload hash whose
    # dig(:meta, :partial) is a boolean.
    def fetch
      cached = Rails.cache.read(key)
      return cached if cached

      payload = yield
      Rails.cache.write(key, payload) unless partial?(payload)
      payload
    end

    private

    attr_reader :portfolio, :from, :to, :benchmark_id

    def partial?(payload)
      !!payload.dig(:meta, :partial)
    end

    # max(latest_price_on) across the portfolio's instruments + benchmark, as an
    # ISO date; "none" when nothing has priced yet (empty portfolio, or a fresh
    # instrument whose backfill has not completed).
    def prices_version
      ids = instrument_ids
      return NONE if ids.empty?

      max = Instrument.where(id: ids).maximum(:latest_price_on)
      max ? max.iso8601 : NONE
    end

    # The instrument ids whose prices can affect this response: everything the
    # portfolio trades or has a recurring rule on, plus the benchmark instrument
    # (its late fetches must rotate the key too).
    def instrument_ids
      ids = Transaction.where(portfolio_id: portfolio.id).distinct.pluck(:instrument_id)
      ids |= RecurringTransaction.where(portfolio_id: portfolio.id).distinct.pluck(:instrument_id)
      ids |= [ benchmark_instrument_id ].compact
      ids
    end

    def benchmark_instrument_id
      return nil if benchmark_id.nil?

      ::Benchmark.where(id: benchmark_id).pick(:instrument_id)
    end
  end
end
