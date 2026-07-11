require "test_helper"

# Stubbed-HTTP unit tests for the Tiingo EOD adapter. All requests hit the
# Faraday :test adapter with recorded fixture bodies (testing-conventions:
# mock at the Faraday boundary) — no test ever touches the real Tiingo API.
class PriceProvider::TiingoTest < ActiveSupport::TestCase
  # A realistic three-row EOD payload: a normal row, a split row
  # (splitFactor = 4.0, the AAPL 4:1), and a dividend row (divCash > 0).
  EOD_ROWS = [
    {
      "date" => "2020-08-28T00:00:00.000Z",
      "open" => 126.01, "high" => 126.44, "low" => 124.58, "close" => 124.81,
      "volume" => 187_630_000, "splitFactor" => 1.0, "divCash" => 0.0
    },
    {
      "date" => "2020-08-31T00:00:00.000Z",
      "open" => 127.58, "high" => 131.0, "low" => 126.0, "close" => 129.04,
      "volume" => 225_702_000, "splitFactor" => 4.0, "divCash" => 0.0
    },
    {
      "date" => "2020-11-06T00:00:00.000Z",
      "open" => 118.32, "high" => 119.2, "low" => 116.13, "close" => 118.69,
      "volume" => 114_457_000, "splitFactor" => 1.0, "divCash" => 0.205
    }
  ].freeze

  def build_adapter(stubs, retry_options: PriceProvider::Base::RETRY_OPTIONS)
    PriceProvider::Tiingo.new(
      api_key: "test-key",
      faraday_adapter: [ :test, stubs ],
      retry_options: retry_options
    )
  end

  def stub_get(body:, status: 200, headers: { "Content-Type" => "application/json" })
    Faraday::Adapter::Test::Stubs.new do |stub|
      stub.get(/.*/) { [ status, headers, body ] }
    end
  end

  test "requires an API key and never leaks it in the error" do
    error = assert_raises PriceProvider::ConfigurationError do
      PriceProvider::Tiingo.new(api_key: nil)
    end
    assert_match(/TIINGO_API_KEY/, error.message)
    refute_match(/test-key/, error.message)
  end

  test "sends the API key as an Authorization header, never in the URL" do
    captured = nil
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.get(/.*/) do |env|
        captured = env
        [ 200, { "Content-Type" => "application/json" }, JSON.dump(EOD_ROWS) ]
      end
    end

    PriceProvider::Tiingo.new(api_key: "secret-abc", faraday_adapter: [ :test, stubs ])
      .fetch_daily("AAPL", from: Date.new(2020, 1, 1))

    assert_equal "Token secret-abc", captured.request_headers["Authorization"]
    refute_includes captured.url.query.to_s, "secret-abc"
  end

  test "fetch_daily returns raw unadjusted OHLCV as BigDecimal, ascending by date" do
    series = build_adapter(stub_get(body: JSON.dump(EOD_ROWS))).fetch_daily("aapl", from: Date.new(2020, 1, 1))

    assert_equal "AAPL", series.symbol
    assert_equal 3, series.bars.size
    assert_equal series.bars.map(&:date), series.bars.map(&:date).sort

    first = series.bars.first
    assert_kind_of BigDecimal, first.close
    assert_equal BigDecimal("124.81"), first.close
    assert_equal BigDecimal("126.01"), first.open
    assert_equal 187_630_000, first.volume
  end

  test "emits a split event only for splitFactor != 1, storing the decimal ratio" do
    series = build_adapter(stub_get(body: JSON.dump(EOD_ROWS))).fetch_daily("AAPL", from: Date.new(2020, 1, 1))

    assert_equal 1, series.splits.size
    split = series.splits.first
    assert_equal Date.new(2020, 8, 31), split.ex_date
    assert_equal BigDecimal("4"), split.ratio
  end

  test "emits a dividend event only for divCash > 0" do
    series = build_adapter(stub_get(body: JSON.dump(EOD_ROWS))).fetch_daily("AAPL", from: Date.new(2020, 1, 1))

    assert_equal 1, series.dividends.size
    div = series.dividends.first
    assert_equal Date.new(2020, 11, 6), div.ex_date
    assert_equal BigDecimal("0.205"), div.cash_per_share
    assert_kind_of BigDecimal, div.cash_per_share
  end

  test "fetch_full_history passes an explicit startDate of 1900-01-01" do
    captured = nil
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.get(/.*/) do |env|
        captured = env
        [ 200, { "Content-Type" => "application/json" }, JSON.dump(EOD_ROWS) ]
      end
    end

    build_adapter(stubs).fetch_full_history("AAPL")

    assert_equal "1900-01-01", captured.params["startDate"]
    assert_nil captured.params["endDate"]
  end

  test "fetch_daily forwards an endDate when a to: bound is given" do
    captured = nil
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.get(/.*/) do |env|
        captured = env
        [ 200, { "Content-Type" => "application/json" }, JSON.dump([]) ]
      end
    end

    build_adapter(stubs).fetch_daily("AAPL", from: Date.new(2024, 1, 1), to: Date.new(2024, 6, 30))

    assert_equal "2024-01-01", captured.params["startDate"]
    assert_equal "2024-06-30", captured.params["endDate"]
  end

  test "validates and skips a bad OHLC row (low <= 0 / high < low) with a warning" do
    rows = [
      { "date" => "2021-01-04", "open" => 10, "high" => 8, "low" => 9, "close" => 8.5,
        "volume" => 1, "splitFactor" => 1.0, "divCash" => 0.0 }, # high < low
      { "date" => "2021-01-05", "open" => 0, "high" => 11, "low" => 0, "close" => 10,
        "volume" => 1, "splitFactor" => 1.0, "divCash" => 0.0 }, # low = 0
      { "date" => "2021-01-06", "open" => 10, "high" => 11, "low" => 9, "close" => 10.5,
        "volume" => 1, "splitFactor" => 1.0, "divCash" => 0.0 }  # good
    ]
    series = build_adapter(stub_get(body: JSON.dump(rows))).fetch_daily("AAPL", from: Date.new(2021, 1, 1))

    assert_equal 1, series.bars.size
    assert_equal Date.new(2021, 1, 6), series.bars.first.date
    assert_equal 2, series.warnings.size
  end

  test "a non-2xx response raises a typed error, never a silent nil" do
    stubs = stub_get(body: JSON.dump({ "detail" => "Not found" }), status: 404)
    assert_raises PriceProvider::UnknownSymbol do
      build_adapter(stubs).fetch_daily("NOPE", from: Date.new(2020, 1, 1))
    end
  end

  test "HTTP 429 raises RateLimited carrying Retry-After" do
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.get(/.*/) { [ 429, { "Retry-After" => "120" }, "rate limited" ] }
    end
    error = assert_raises PriceProvider::RateLimited do
      build_adapter(stubs).fetch_daily("AAPL", from: Date.new(2020, 1, 1))
    end
    assert_equal 120, error.retry_after
  end

  test "credentials rejected (401) raises ConfigurationError without leaking the key" do
    stubs = stub_get(body: "unauthorized", status: 401)
    error = assert_raises PriceProvider::ConfigurationError do
      build_adapter(stubs).fetch_daily("AAPL", from: Date.new(2020, 1, 1))
    end
    refute_match(/test-key/, error.message)
  end

  test "a 5xx response raises ServerError" do
    stubs = stub_get(body: "boom", status: 503)
    assert_raises PriceProvider::ServerError do
      build_adapter(stubs, retry_options: PriceProvider::Base::RETRY_OPTIONS.merge(max: 0))
        .fetch_daily("AAPL", from: Date.new(2020, 1, 1))
    end
  end

  test "a malformed (non-array) 2xx payload raises MalformedResponse" do
    stubs = stub_get(body: JSON.dump({ "unexpected" => "object" }))
    assert_raises PriceProvider::MalformedResponse do
      build_adapter(stubs).fetch_daily("AAPL", from: Date.new(2020, 1, 1))
    end
  end

  test "invalid JSON in a 2xx response raises MalformedResponse" do
    stubs = stub_get(body: "<html>not json</html>")
    assert_raises PriceProvider::MalformedResponse do
      build_adapter(stubs).fetch_daily("AAPL", from: Date.new(2020, 1, 1))
    end
  end
end
