require "test_helper"

# backlog #027: GET /api/v1/benchmarks — the curated seeded list.
module Api
  module V1
    class BenchmarksControllerTest < ActionDispatch::IntegrationTest
      setup do
        seed_curated_benchmarks
        sign_in_as users(:one)
      end

      test "requires an authenticated session and answers the 401 envelope" do
        sign_out

        get api_v1_benchmarks_path

        assert_response :unauthorized
        error = JSON.parse(response.body).fetch("error")
        assert_equal "unauthenticated", error.fetch("code")
        assert error.key?("details")
      end

      test "returns the curated list with id + name + symbol in seed order" do
        get api_v1_benchmarks_path

        assert_response :ok
        benchmarks = JSON.parse(response.body).fetch("benchmarks")

        assert_equal [ "S&P 500 (SPY)", "Total US Stock Market (VTI)", "Nasdaq-100 (QQQ)" ],
          benchmarks.map { |b| b["name"] }
        assert_equal %w[SPY VTI QQQ], benchmarks.map { |b| b["symbol"] }
        benchmarks.each do |b|
          assert_equal %w[id name symbol].sort, b.keys.sort,
            "benchmark items must match the frozen contract shape"
          assert_kind_of Integer, b["id"]
        end
      end

      private

      # Mirrors db/seeds.rb (fixtureless suite: data is created per test).
      def seed_curated_benchmarks
        [
          { symbol: "SPY", name: "S&P 500 (SPY)" },
          { symbol: "VTI", name: "Total US Stock Market (VTI)" },
          { symbol: "QQQ", name: "Nasdaq-100 (QQQ)" }
        ].each do |seed|
          instrument = Instrument.create!(symbol: seed[:symbol], instrument_type: "etf", currency: "USD")
          ::Benchmark.create!(instrument: instrument, name: seed[:name])
        end
      end
    end
  end
end
