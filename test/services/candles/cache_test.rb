require "test_helper"

# backlog #033: the candles caching-key scheme in Solid Cache
# (docs/PLAN.md § Caching). Invalidation is by KEY ROTATION only.
class Candles::CacheTest < ActiveSupport::TestCase
  include DomainTestHelper

  MON = Date.new(2026, 7, 6)
  FRI = Date.new(2026, 7, 10)

  setup do
    @portfolio = create_portfolio
    create_trading_days(MON, FRI)
    @aapl = create_instrument(symbol: "AAPL")
    @msft = create_instrument(symbol: "MSFT")
    seed_prices(@aapl, { MON => "100" })
    seed_prices(@msft, { MON => "200" })
    @aapl.update!(latest_price_on: Date.new(2026, 7, 8))
    @msft.update!(latest_price_on: Date.new(2026, 7, 10))
    buy!(@portfolio, @aapl, on: MON, shares: "1", price: "100")
    buy!(@portfolio, @msft, on: MON, shares: "1", price: "200")
  end

  def cache_for(from: MON, to: FRI, benchmark_id: nil, portfolio: @portfolio)
    Candles::Cache.new(portfolio: portfolio, from: from, to: to, benchmark_id: benchmark_id)
  end

  # --- Key scheme (frozen) ---

  test "key exactly matches the frozen scheme with both version components and benchmark_id" do
    @portfolio.reload
    expected = [
      "candles", "v1", @portfolio.id, @portfolio.series_version,
      "2026-07-10",              # prices_version = max(latest_price_on) across instruments
      "2026-07-06", "2026-07-10",
      "none"                     # no benchmark requested
    ].join("/")

    assert_equal expected, cache_for.key
  end

  test "benchmark_id appears in the key and distinguishes the benchmark variant" do
    benchmark = curated_benchmark
    with_bm = cache_for(benchmark_id: benchmark.id).key
    without_bm = cache_for(benchmark_id: nil).key

    assert_includes with_bm, "/#{benchmark.id}"
    assert_not_equal with_bm, without_bm, "benchmark on/off must be different cache entries"
  end

  # --- prices_version = max latest_price_on across ALL portfolio instruments ---

  test "prices_version is the max latest_price_on across all portfolio instruments, not just one" do
    # MSFT (2026-07-10) currently dominates AAPL (2026-07-08).
    assert_includes cache_for.key.split("/"), "2026-07-10"
  end

  test "a late-landing ticker fetch advancing any instrument's latest_price_on rotates the key" do
    before = cache_for.key

    @aapl.update!(latest_price_on: Date.new(2026, 7, 11)) # now dominates MSFT
    after = cache_for.key

    assert_not_equal before, after, "a late ticker fetch must rotate the key"
    assert_includes after.split("/"), "2026-07-11"
  end

  test "the benchmark instrument's latest_price_on also participates in prices_version" do
    benchmark = curated_benchmark
    benchmark.instrument.update!(latest_price_on: Date.new(2026, 7, 20)) # dominates everything

    key = cache_for(benchmark_id: benchmark.id).key

    assert_includes key.split("/"), "2026-07-20",
      "a late benchmark fetch must rotate the key even though benchmark_id is unchanged"
  end

  test "prices_version is 'none' for a portfolio with no priced instruments" do
    empty = create_portfolio(name: "Empty")
    assert_includes cache_for(portfolio: empty).key.split("/"), "none"
  end

  # --- Caching behaviour ---

  test "a miss computes and caches; a hit returns the cached payload without recomputing" do
    calls = 0
    payload = { candles: [], meta: { partial: false } }

    first = cache_for.fetch { calls += 1; payload }
    second = cache_for.fetch { calls += 1; payload }

    assert_equal 1, calls, "the block must run only on the miss"
    assert_equal payload, first
    assert_equal payload, second
  end

  test "a hit skips the (expensive) valuation recompute — asserted by query count" do
    block = -> { serialized_valuation }

    miss_queries = count_queries { cache_for.fetch(&block) }
    hit_queries  = count_queries { cache_for.fetch(&block) }

    assert_operator hit_queries, :<, miss_queries,
      "a cache hit must not re-run the valuation sweep"
  end

  test "a partial payload is never written to the cache" do
    calls = 0
    partial = { candles: [], meta: { partial: true } }

    cache_for.fetch { calls += 1; partial }
    cache_for.fetch { calls += 1; partial }

    assert_equal 2, calls, "a partial payload must recompute every time (never cached)"
  end

  # --- Invalidation by key rotation on a series_version bump ---

  test "a series_version bump (e.g. a new transaction) rotates the key to a fresh compute" do
    calls = 0
    block = -> { calls += 1; { candles: [], meta: { partial: false } } }

    cache_for.fetch(&block)                       # miss -> cached under old series_version
    buy!(@portfolio, @aapl, on: MON, shares: "1", price: "100") # bumps series_version
    @portfolio.reload
    cache_for.fetch(&block)                       # different key -> fresh compute

    assert_equal 2, calls, "a series_version bump must force a fresh compute via the new key"
  end

  private

  def serialized_valuation
    result = Portfolios::Valuation.call(portfolio: @portfolio, from: MON, to: FRI)
    { candles: result.candles.map { |c| { t: c.date.iso8601, c: c.close.to_s("F") } },
      meta: { partial: result.meta[:partial] } }
  end

  def curated_benchmark
    spy = create_instrument(symbol: "SPY", instrument_type: "etf")
    ::Benchmark.find_by(instrument: spy) || ::Benchmark.create!(instrument: spy, name: "S&P 500 (SPY)")
  end
end
