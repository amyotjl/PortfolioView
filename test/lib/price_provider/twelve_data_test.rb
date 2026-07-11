require "test_helper"

# Stubbed-HTTP unit tests for the Twelve Data FALLBACK adapter. Every request
# hits the Faraday :test adapter — no real API calls. These tests also lock in
# the adapter's deliberate restrictions: forward-delta-only, adjust=none, and
# no split/dividend ingestion (docs/PLAN.md § Free data sources).
class PriceProvider::TwelveDataTest < ActiveSupport::TestCase
  OK_BODY = {
    "meta" => { "symbol" => "AAPL", "interval" => "1day" },
    "values" => [
      { "datetime" => "2026-07-08", "open" => "210.10", "high" => "212.00",
        "low" => "209.50", "close" => "211.25", "volume" => "40000000" },
      { "datetime" => "2026-07-09", "open" => "211.30", "high" => "213.40",
        "low" => "210.90", "close" => "213.10", "volume" => "38000000" }
    ],
    "status" => "ok"
  }.freeze

  def build_adapter(stubs, api_key: "test-key")
    PriceProvider::TwelveData.new(api_key:, faraday_adapter: [ :test, stubs ])
  end

  def stub_get(body:, status: 200, headers: { "Content-Type" => "application/json" })
    Faraday::Adapter::Test::Stubs.new do |stub|
      stub.get(/.*/) { [ status, headers, body ] }
    end
  end

  def capture_env(body: OK_BODY)
    captured = nil
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.get(/.*/) do |env|
        captured = env
        [ 200, { "Content-Type" => "application/json" }, JSON.dump(body) ]
      end
    end
    yield build_adapter(stubs)
    captured
  end

  test "normal forward-delta fetch returns raw bars as BigDecimal, ascending" do
    series = build_adapter(stub_get(body: JSON.dump(OK_BODY)))
             .fetch_delta("aapl", since: Date.new(2026, 7, 8))

    assert_equal "AAPL", series.symbol
    assert_equal 2, series.bars.size
    assert_equal series.bars.map(&:date), series.bars.map(&:date).sort
    assert_kind_of BigDecimal, series.bars.first.close
    assert_equal BigDecimal("211.25"), series.bars.first.close
    assert_equal 40_000_000, series.bars.first.volume
  end

  test "every request explicitly passes adjust=none and a start_date" do
    env = capture_env do |adapter|
      adapter.fetch_delta("AAPL", since: Date.new(2026, 7, 1))
    end

    assert_equal "none", env.params["adjust"]
    assert_equal "1day", env.params["interval"]
    assert_equal "2026-07-01", env.params["start_date"]
    assert_equal "ASC", env.params["order"]
  end

  test "auth key travels in the Authorization header, never in the URL" do
    env = nil
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.get(/.*/) do |e|
        env = e
        [ 200, { "Content-Type" => "application/json" }, JSON.dump(OK_BODY) ]
      end
    end
    build_adapter(stubs, api_key: "secret-xyz").fetch_delta("AAPL", since: Date.new(2026, 7, 1))

    assert_equal "apikey secret-xyz", env.request_headers["Authorization"]
    refute_includes env.url.query.to_s, "secret-xyz"
  end

  test "the returned series NEVER carries split or dividend events" do
    series = build_adapter(stub_get(body: JSON.dump(OK_BODY)))
             .fetch_delta("AAPL", since: Date.new(2026, 7, 8))

    assert_empty series.splits
    assert_empty series.dividends
  end

  test "there is no full-history / backfill method on the public interface" do
    adapter = build_adapter(stub_get(body: JSON.dump(OK_BODY)))

    refute_respond_to adapter, :fetch_full_history
    refute_respond_to adapter, :fetch_daily
    assert_respond_to adapter, :fetch_delta
  end

  test "calling fetch_delta without a since-date raises a typed refusal" do
    adapter = build_adapter(stub_get(body: JSON.dump(OK_BODY)))

    error = assert_raises PriceProvider::BackfillNotSupported do
      adapter.fetch_delta("AAPL", since: nil)
    end
    assert_match(/forward-delta/i, error.message)
    assert_kind_of PriceProvider::Error, error
  end

  test "a blank since-date is also refused" do
    adapter = build_adapter(stub_get(body: JSON.dump(OK_BODY)))
    assert_raises PriceProvider::BackfillNotSupported do
      adapter.fetch_delta("AAPL", since: "")
    end
  end

  test "an error object returned inside a 200 body is mapped to a typed error" do
    body = { "code" => 404, "message" => "**symbol** not found: ZZZZ", "status" => "error" }
    assert_raises PriceProvider::UnknownSymbol do
      build_adapter(stub_get(body: JSON.dump(body))).fetch_delta("ZZZZ", since: Date.new(2026, 7, 1))
    end
  end

  test "a 429 error object maps to RateLimited with a retry_after" do
    body = { "code" => 429, "message" => "You have run out of API credits", "status" => "error" }
    error = assert_raises PriceProvider::RateLimited do
      build_adapter(stub_get(body: JSON.dump(body))).fetch_delta("AAPL", since: Date.new(2026, 7, 1))
    end
    assert error.retry_after.to_i.positive?
  end

  test "a 401 error object maps to ConfigurationError without leaking the key" do
    body = { "code" => 401, "message" => "Invalid API key", "status" => "error" }
    error = assert_raises PriceProvider::ConfigurationError do
      build_adapter(stub_get(body: JSON.dump(body)), api_key: "leaky").fetch_delta("AAPL", since: Date.new(2026, 7, 1))
    end
    refute_match(/leaky/, error.message)
  end

  test "a 'no data available' 400 is a legitimate empty delta, not an error" do
    body = { "code" => 400, "message" => "No data is available on the specified dates", "status" => "error" }
    series = build_adapter(stub_get(body: JSON.dump(body))).fetch_delta("AAPL", since: Date.new(2030, 1, 1))

    assert series.empty?
    assert_empty series.bars
  end

  test "invalid JSON in a 2xx response raises MalformedResponse" do
    stubs = stub_get(body: "<html>nope</html>")
    assert_raises PriceProvider::MalformedResponse do
      build_adapter(stubs).fetch_delta("AAPL", since: Date.new(2026, 7, 1))
    end
  end

  test "bad OHLC delta rows are validated and skipped with a warning" do
    body = {
      "status" => "ok",
      "values" => [
        { "datetime" => "2026-07-08", "open" => "10", "high" => "8", "low" => "9", "close" => "9",
          "volume" => "1" }, # high < low
        { "datetime" => "2026-07-09", "open" => "10", "high" => "11", "low" => "9", "close" => "10",
          "volume" => "1" }  # good
      ]
    }
    series = build_adapter(stub_get(body: JSON.dump(body))).fetch_delta("AAPL", since: Date.new(2026, 7, 8))

    assert_equal 1, series.bars.size
    assert_equal 1, series.warnings.size
  end
end
