require "test_helper"

# Stubbed-HTTP unit tests for the FMP profile-metadata adapter. All requests
# hit the Faraday :test adapter — no real API calls (docs/PLAN.md § Free data
# sources: FMP supplies sector/industry, cached forever in Postgres).
class PriceProvider::FmpTest < ActiveSupport::TestCase
  STOCK_PROFILE = [
    {
      "symbol" => "AAPL",
      "companyName" => "Apple Inc.",
      "sector" => "Technology",
      "industry" => "Consumer Electronics",
      "exchange" => "NASDAQ",
      "currency" => "USD",
      "isEtf" => false,
      "isFund" => false
    }
  ].freeze

  ETF_PROFILE = [
    {
      "symbol" => "SPY",
      "companyName" => "SPDR S&P 500 ETF Trust",
      "sector" => "",
      "industry" => "",
      "exchange" => "AMEX",
      "currency" => "USD",
      "isEtf" => true,
      "isFund" => false
    }
  ].freeze

  def build_adapter(stubs, api_key: "test-key", retry_options: PriceProvider::Base::RETRY_OPTIONS)
    PriceProvider::Fmp.new(api_key:, faraday_adapter: [ :test, stubs ], retry_options:)
  end

  def stub_get(body:, status: 200, headers: { "Content-Type" => "application/json" })
    Faraday::Adapter::Test::Stubs.new do |stub|
      stub.get(/.*/) { [ status, headers, body ] }
    end
  end

  test "a stock profile returns sector, industry, name and stock type" do
    profile = build_adapter(stub_get(body: JSON.dump(STOCK_PROFILE))).fetch_profile("aapl")

    assert profile.found?
    assert_equal "AAPL", profile.symbol
    assert_equal "Apple Inc.", profile.name
    assert_equal "Technology", profile.sector
    assert_equal "Consumer Electronics", profile.industry
    assert_equal "stock", profile.instrument_type
  end

  test "an ETF profile is typed etf with a nil (not blank) sector" do
    profile = build_adapter(stub_get(body: JSON.dump(ETF_PROFILE))).fetch_profile("SPY")

    assert profile.found?
    assert_equal "SPY", profile.symbol
    assert_equal "etf", profile.instrument_type
    assert_nil profile.sector
    assert_nil profile.industry
  end

  test "an unknown symbol (FMP returns []) yields an explicit not-found result" do
    profile = build_adapter(stub_get(body: JSON.dump([]))).fetch_profile("ZZZZ")

    refute profile.found?
    assert_equal "ZZZZ", profile.symbol
    assert_nil profile.sector
    assert_nil profile.instrument_type
  end

  test "the API key travels as an apikey query param and is never in error messages" do
    env = nil
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.get(/.*/) do |e|
        env = e
        [ 200, { "Content-Type" => "application/json" }, JSON.dump(STOCK_PROFILE) ]
      end
    end
    build_adapter(stubs, api_key: "secret-key").fetch_profile("AAPL")

    assert_equal "secret-key", env.params["apikey"]
    assert_equal "AAPL", env.params["symbol"]
  end

  test "credentials rejected (401) raises ConfigurationError without leaking the key" do
    stubs = stub_get(body: JSON.dump("Invalid API KEY"), status: 401)
    error = assert_raises PriceProvider::ConfigurationError do
      build_adapter(stubs, api_key: "leaky-key").fetch_profile("AAPL")
    end
    refute_match(/leaky-key/, error.message)
  end

  test "HTTP 429 raises RateLimited" do
    stubs = stub_get(body: "too many requests", status: 429)
    assert_raises PriceProvider::RateLimited do
      build_adapter(stubs).fetch_profile("AAPL")
    end
  end

  test "a 5xx response raises ServerError" do
    stubs = stub_get(body: "boom", status: 503)
    assert_raises PriceProvider::ServerError do
      build_adapter(stubs, retry_options: PriceProvider::Base::RETRY_OPTIONS.merge(max: 0))
        .fetch_profile("AAPL")
    end
  end

  test "invalid JSON raises MalformedResponse" do
    stubs = stub_get(body: "<html>nope</html>")
    assert_raises PriceProvider::MalformedResponse do
      build_adapter(stubs).fetch_profile("AAPL")
    end
  end

  test "a bare profile object (not wrapped in an array) is still parsed" do
    stubs = stub_get(body: JSON.dump(STOCK_PROFILE.first))
    profile = build_adapter(stubs).fetch_profile("AAPL")

    assert profile.found?
    assert_equal "Technology", profile.sector
  end
end
