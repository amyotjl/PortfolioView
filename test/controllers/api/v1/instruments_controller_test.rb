require "test_helper"

# backlog #026: instruments search (local directory only) + price prefill.
module Api
  module V1
    class InstrumentsControllerTest < ActionDispatch::IntegrationTest
      include PricePipelineTestHelper

      setup do
        sign_in_as users(:one)
      end

      # --- Auth required (both endpoints) ---

      test "search requires an authenticated session and answers the 401 envelope" do
        sign_out

        get search_api_v1_instruments_path, params: { q: "AAP" }

        assert_response :unauthorized
        assert_error_envelope "unauthenticated"
      end

      test "price requires an authenticated session and answers the 401 envelope" do
        instrument = create_priced_instrument
        sign_out

        get price_api_v1_instrument_path(instrument), params: { date: "2024-01-05" }

        assert_response :unauthorized
        assert_error_envelope "unauthenticated"
      end

      # --- GET /api/v1/instruments/search ---

      test "search matches symbol prefix case-insensitively in the frozen shape" do
        directory_entry symbol: "AAPL", name: "Apple Inc"
        directory_entry symbol: "MSFT", name: "Microsoft Corporation"

        get search_api_v1_instruments_path, params: { q: "aap" }

        assert_response :ok
        instruments = JSON.parse(response.body).fetch("instruments")
        assert_equal [ "AAPL" ], instruments.map { |i| i["symbol"] }
        assert_equal(
          %w[symbol name exchange asset_type currency].sort,
          instruments.first.keys.sort,
          "search results must match the frozen contract shape"
        )
        assert_equal "Apple Inc", instruments.first["name"]
      end

      test "search matches company name case-insensitively" do
        directory_entry symbol: "AAPL", name: "Apple Inc"
        directory_entry symbol: "APLE", name: "Apple Hospitality REIT"
        directory_entry symbol: "MSFT", name: "Microsoft Corporation"

        get search_api_v1_instruments_path, params: { q: "apple" }

        assert_response :ok
        symbols = JSON.parse(response.body).fetch("instruments").map { |i| i["symbol"] }
        assert_equal %w[AAPL APLE].sort, symbols.sort
      end

      test "an exact symbol match ranks before prefix and name matches" do
        directory_entry symbol: "AA", name: "Alcoa Corporation"
        directory_entry symbol: "AAPL", name: "Apple Inc"
        directory_entry symbol: "GOAA", name: "AA Mining Group"

        get search_api_v1_instruments_path, params: { q: "AA" }

        assert_response :ok
        symbols = JSON.parse(response.body).fetch("instruments").map { |i| i["symbol"] }
        assert_equal "AA", symbols.first, "exact symbol match must rank first"
        assert_equal %w[AA AAPL GOAA], symbols, "then prefix matches, then name matches"
      end

      test "search result count is bounded" do
        25.times { |i| directory_entry symbol: format("QQ%02d", i), name: "Quantum #{i}" }

        get search_api_v1_instruments_path, params: { q: "QQ" }

        assert_response :ok
        assert_equal ListedInstrument::SEARCH_LIMIT,
          JSON.parse(response.body).fetch("instruments").size
      end

      test "LIKE metacharacters in the query are matched literally, not as wildcards" do
        directory_entry symbol: "AAPL", name: "Apple Inc"
        directory_entry symbol: "MSFT", name: "Microsoft Corporation"

        get search_api_v1_instruments_path, params: { q: "%%" }
        assert_response :ok
        assert_empty JSON.parse(response.body).fetch("instruments"),
          "an escaped %% must not wildcard-match the whole directory"

        get search_api_v1_instruments_path, params: { q: "AA__" }
        assert_response :ok
        assert_empty JSON.parse(response.body).fetch("instruments"),
          "an escaped _ must not single-char-wildcard AAPL"
      end

      test "a query shorter than 2 characters answers 422 mapped onto the q field" do
        get search_api_v1_instruments_path, params: { q: "A" }

        assert_response :unprocessable_entity
        details = assert_error_envelope("validation_failed")
        assert details.key?("q"), "422 details must map onto the q field"
      end

      test "a missing query answers 422 mapped onto the q field" do
        get search_api_v1_instruments_path

        assert_response :unprocessable_entity
        details = assert_error_envelope("validation_failed")
        assert details.key?("q")
      end

      test "search never makes a provider HTTP call" do
        directory_entry symbol: "AAPL", name: "Apple Inc"
        provider_tripwire = ->(*, **) { flunk "search must not instantiate a price provider" }

        stub_new(PriceProvider::Tiingo, provider_tripwire) do
          stub_new(PriceProvider::TwelveData, provider_tripwire) do
            stub_new(PriceProvider::Fmp, provider_tripwire) do
              get search_api_v1_instruments_path, params: { q: "AAPL" }
            end
          end
        end

        assert_response :ok
      end

      # --- GET /api/v1/instruments/:id/price ---

      test "price returns the close for an exact trading-day date, money as a string" do
        instrument = create_priced_instrument

        get price_api_v1_instrument_path(instrument), params: { date: "2024-01-05" }

        assert_response :ok
        price = JSON.parse(response.body).fetch("price")
        assert_equal instrument.id, price["instrument_id"]
        assert_equal "2024-01-05", price["date"]
        assert_equal "187.5", price["close"]
        assert_kind_of String, price["close"], "money fields must serialize as strings"
      end

      test "a weekend-dated request returns the prior trading day's close" do
        instrument = create_priced_instrument

        # 2024-01-06 is a Saturday; the most recent trading day is Friday the 5th.
        get price_api_v1_instrument_path(instrument), params: { date: "2024-01-06" }

        assert_response :ok
        price = JSON.parse(response.body).fetch("price")
        assert_equal "2024-01-05", price["date"]
        assert_equal "187.5", price["close"]
      end

      test "a date before the instrument's price history answers the 404 envelope, never a 500" do
        instrument = create_priced_instrument

        get price_api_v1_instrument_path(instrument), params: { date: "2023-12-31" }

        assert_response :not_found
        assert_error_envelope "price_unavailable"
      end

      test "an unknown instrument id answers the 404 envelope" do
        get price_api_v1_instrument_path(id: 999_999), params: { date: "2024-01-05" }

        assert_response :not_found
        assert_error_envelope "not_found"
      end

      test "a missing or malformed date answers 422 mapped onto the date field" do
        instrument = create_priced_instrument

        get price_api_v1_instrument_path(instrument)
        assert_response :unprocessable_entity
        assert assert_error_envelope("validation_failed").key?("date")

        get price_api_v1_instrument_path(instrument), params: { date: "01/05/2024" }
        assert_response :unprocessable_entity
        assert assert_error_envelope("validation_failed").key?("date")
      end

      private

      def directory_entry(symbol:, name:, exchange: "NYSE", asset_type: "Stock", currency: "USD")
        ListedInstrument.create!(symbol: symbol, name: name, exchange: exchange,
                                 asset_type: asset_type, currency: currency)
      end

      # An instrument with closes on Thu 2024-01-04 and Fri 2024-01-05
      # (2024-01-06/07 is a weekend).
      def create_priced_instrument
        create_instrument(symbol: "AAPL").tap do |instrument|
          instrument.daily_prices.create!(date: Date.new(2024, 1, 4), open: 182, high: 184,
                                          low: 181, close: 183.25, volume: 1, source: "tiingo")
          instrument.daily_prices.create!(date: Date.new(2024, 1, 5), open: 186, high: 188,
                                          low: 185, close: 187.5, volume: 1, source: "tiingo")
        end
      end

      # Asserts the frozen envelope shape and returns details for field checks.
      def assert_error_envelope(code)
        error = JSON.parse(response.body).fetch("error")
        assert_equal code, error.fetch("code")
        assert_kind_of String, error.fetch("message")
        assert error.key?("details"), "envelope must always carry details"
        error.fetch("details")
      end
    end
  end
end
