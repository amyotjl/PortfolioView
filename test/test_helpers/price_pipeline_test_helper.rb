# Shared helpers for the price-pipeline job/service tests (backlog #011-#016).
#
# Adapter interactions are stubbed at the PriceProvider BOUNDARY by injecting a
# StubProvider in place of the real Faraday-backed adapter (via
# `PriceProvider::Tiingo.stub(:new, ...)` etc.). We stub the adapter OBJECTS
# rather than replay Faraday fixtures here because these tests exercise JOB
# orchestration — the overlap drift check, series_version bumps, fan-out target
# selection, failover routing, upsert idempotency — not HTTP/JSON parsing, which
# the adapter unit tests already cover at the Faraday :test-adapter boundary.
# Object-stubbing also lets us construct exact DailySeries value objects
# (including deliberately malformed bars and simulated typed errors) that would
# be awkward to elicit from recorded HTTP fixtures.
module PricePipelineTestHelper
  # Build a frozen PriceProvider::DailySeries from lightweight row hashes.
  # bars:      [{ date:, open:, high:, low:, close:, volume: }]
  # splits:    [{ ex_date:, ratio: }]
  # dividends: [{ ex_date:, cash_per_share: }]
  def build_series(symbol: "AAPL", bars: [], splits: [], dividends: [], warnings: [])
    PriceProvider::DailySeries.new(
      symbol: symbol,
      bars: bars.map { |b|
        PriceProvider::Bar.new(
          date: b[:date],
          open: to_d(b[:open]), high: to_d(b[:high]),
          low: to_d(b[:low]), close: to_d(b[:close]),
          volume: b.fetch(:volume, 0)
        )
      }.freeze,
      splits: splits.map { |s| PriceProvider::Split.new(ex_date: s[:ex_date], ratio: to_d(s[:ratio])) }.freeze,
      dividends: dividends.map { |d| PriceProvider::Dividend.new(ex_date: d[:ex_date], cash_per_share: to_d(d[:cash_per_share])) }.freeze,
      warnings: warnings.freeze
    )
  end

  def to_d(value)
    return value if value.is_a?(BigDecimal)
    BigDecimal(value.to_s)
  end

  # A stand-in for a PriceProvider adapter. Records calls and either returns a
  # pre-built DailySeries or raises a pre-built typed error.
  class StubProvider
    attr_reader :calls

    def initialize(series: nil, error: nil)
      @series = series
      @error = error
      @calls = []
    end

    def fetch_full_history(symbol, to: nil)
      record(:full_history, symbol, to)
    end

    def fetch_daily(symbol, from:, to: nil)
      record(:fetch_daily, symbol, from, to)
    end

    def fetch_delta(symbol, since:, to: nil)
      record(:fetch_delta, symbol, since, to)
    end

    def fetch_profile(symbol)
      record(:fetch_profile, symbol)
    end

    def called?(kind) = @calls.any? { |c| c.first == kind }
    def call_count = @calls.size

    private

    def record(kind, *args)
      @calls << [ kind, *args ]
      raise @error if @error
      @series
    end
  end

  def create_instrument(symbol: "AAPL", instrument_type: "stock", **attrs)
    Instrument.create!(symbol: symbol, instrument_type: instrument_type, currency: "USD", **attrs)
  end

  # Minitest 6 dropped minitest/mock (no Object#stub), so we inject collaborators
  # by temporarily overriding a class's `.new` for the duration of the block.
  # The adapters/budget don't define a custom `self.new`, so removing the
  # singleton method restores the inherited Class#new afterward. `replacement`
  # may be an object (returned for every `.new`) or a callable invoked with the
  # `.new` arguments (to dispatch on, e.g., the provider name).
  def stub_new(klass, replacement)
    klass.define_singleton_method(:new) do |*args, **kwargs|
      replacement.respond_to?(:call) ? replacement.call(*args, **kwargs) : replacement
    end
    yield
  ensure
    klass.singleton_class.send(:remove_method, :new)
  end
end
