require "test_helper"

# backlog #064: the native export envelope.
module Portfolios
  module Transfer
    class ExportTest < ActiveSupport::TestCase
      include DomainTestHelper

      setup do
        @user = users(:one)
        @spy = create_instrument(symbol: "SPY", instrument_type: "etf")
        @benchmark = ::Benchmark.create!(instrument: @spy, name: "S&P 500 (SPY)")
        @aapl = create_instrument(symbol: "AAPL")
        @portfolio = create_portfolio(name: "Retirement", user: @user, benchmark: @benchmark)
      end

      def envelope(**kwargs) = Export.new(user: @user, **kwargs).call

      # --- Envelope ---

      test "stamps the format and version so an importer can refuse a foreign file" do
        payload = envelope

        assert_equal NATIVE_FORMAT, payload[:format]
        assert_equal NATIVE_VERSION, payload[:version]
        assert_match(/\A\d{4}-\d{2}-\d{2}T.*Z\z/, payload[:exported_at])
      end

      test "the filename is sortable and carries no user data" do
        exporter = Export.new(user: @user, exported_at: Time.utc(2026, 3, 4, 9, 8, 7))

        assert_equal "portfolioview-portfolios-20260304-090807.json", exporter.filename
      end

      # --- Nothing environment-specific leaks into the file ---

      test "references the benchmark by NAME, never by id" do
        payload = envelope

        assert_equal "S&P 500 (SPY)", payload[:portfolios].first[:benchmark]
        assert_not payload[:portfolios].first.key?(:benchmark_id)
      end

      test "carries no primary keys, series_version or timestamps" do
        buy!(@portfolio, @aapl, on: Date.new(2024, 1, 5), shares: "10", price: "150.25")

        portfolio = envelope[:portfolios].first
        transaction = portfolio[:transactions].first

        assert_equal %i[name benchmark transactions recurring_transactions].sort, portfolio.keys.sort
        %i[id portfolio_id instrument_id series_version created_at updated_at].each do |key|
          assert_not transaction.key?(key), "#{key} must not be exported — ids don't port between databases"
        end
      end

      test "a portfolio with no benchmark exports null rather than omitting the key" do
        create_portfolio(name: "Cash", user: @user)

        cash = envelope[:portfolios].find { |p| p[:name] == "Cash" }
        assert_nil cash[:benchmark]
      end

      # --- Decimals stay strings ---

      test "money and share figures are strings, never JSON floats" do
        buy!(@portfolio, @aapl, on: Date.new(2024, 1, 5), shares: "1.23456789", price: "150.254321", fees: "4.95")

        transaction = envelope[:portfolios].first[:transactions].first

        assert_equal "1.23456789", transaction[:shares]
        assert_equal "150.254321", transaction[:price]
        assert_equal "4.95", transaction[:fees]
        # Round-tripping through JSON must not introduce a float anywhere.
        reparsed = JSON.parse(JSON.generate(envelope))
        assert reparsed.to_s.exclude?("e-"), "no scientific-notation floats in the payload"
      end

      # --- Instrument identity travels with the file ---

      test "exports the full identity of every referenced instrument, deduped and symbol-sorted" do
        zeqt = Instrument.create!(symbol: "ZEQT.TO", name: "BMO All-Equity ETF",
                                  instrument_type: "etf", currency: "CAD", sector: "Financials",
                                  skip_provider_jobs: true)
        buy!(@portfolio, @aapl, on: Date.new(2024, 1, 5), shares: "1", price: "100")
        buy!(@portfolio, @aapl, on: Date.new(2024, 2, 5), shares: "1", price: "100")
        buy!(@portfolio, zeqt, on: Date.new(2024, 3, 5), shares: "1", price: "20")

        instruments = envelope[:instruments]

        assert_equal %w[AAPL ZEQT.TO], instruments.map { |i| i[:symbol] }
        cad = instruments.last
        assert_equal "CAD", cad[:currency], "currency must travel — it's what makes a non-US listing round-trip"
        assert_equal "etf", cad[:instrument_type]
        assert_equal "Financials", cad[:sector]
      end

      test "benchmark instruments are not exported (the benchmark is referenced by name)" do
        buy!(@portfolio, @aapl, on: Date.new(2024, 1, 5), shares: "1", price: "100")

        assert_equal %w[AAPL], envelope[:instruments].map { |i| i[:symbol] }
      end

      # --- Recurring linkage ---

      test "links a materialized transaction to its rule by a FILE-LOCAL key" do
        rule = @portfolio.recurring_transactions.create!(
          instrument: @aapl, amount_type: "dollars", dollar_amount: "100",
          frequency: "monthly", anchor_on: Date.new(2024, 1, 31), next_run_on: Date.new(2124, 1, 31)
        )
        buy!(@portfolio, @aapl, on: Date.new(2024, 2, 1), shares: "1", price: "100",
             recurring_transaction: rule, scheduled_for: Date.new(2024, 1, 31))

        portfolio = envelope[:portfolios].first
        key = portfolio[:recurring_transactions].first[:key]

        assert_equal "r1", key
        assert_equal key, portfolio[:transactions].first[:recurring_key]
        assert_equal "2024-01-31", portfolio[:transactions].first[:scheduled_for],
                     "scheduled_for must survive — it is the materialization idempotency guard"
      end

      test "a standalone transaction carries a null recurring key" do
        buy!(@portfolio, @aapl, on: Date.new(2024, 1, 5), shares: "1", price: "100")

        transaction = envelope[:portfolios].first[:transactions].first
        assert_nil transaction[:recurring_key]
        assert_nil transaction[:scheduled_for]
      end

      test "materializer runtime state is not exported" do
        @portfolio.recurring_transactions.create!(
          instrument: @aapl, amount_type: "dollars", dollar_amount: "100",
          frequency: "monthly", anchor_on: Date.new(2024, 1, 31), next_run_on: Date.new(2124, 1, 31),
          paused_reason: "insufficient_history", consecutive_skips: 3
        )

        rule = envelope[:portfolios].first[:recurring_transactions].first

        assert_not rule.key?(:paused_reason), "paused_reason is runtime state, not user intent"
        assert_not rule.key?(:consecutive_skips)
      end

      # --- Scoping and determinism ---

      test "exports only the current user's portfolios" do
        create_portfolio(name: "Not Yours", user: users(:two))

        assert_equal [ "Retirement" ], envelope[:portfolios].map { |p| p[:name] }
      end

      test "portfolio_ids narrows the export" do
        other = create_portfolio(name: "Growth", user: @user)

        assert_equal [ "Growth" ], envelope(portfolio_ids: [ other.id ])[:portfolios].map { |p| p[:name] }
      end

      test "an id belonging to another user simply yields nothing (no existence leak)" do
        foreign = create_portfolio(name: "Not Yours", user: users(:two))

        assert_empty envelope(portfolio_ids: [ foreign.id ])[:portfolios]
      end

      test "two exports of unchanged data are byte-identical" do
        buy!(@portfolio, @aapl, on: Date.new(2024, 2, 5), shares: "2", price: "100")
        buy!(@portfolio, @aapl, on: Date.new(2024, 1, 5), shares: "1", price: "100")
        at = Time.utc(2026, 3, 4)

        first = JSON.generate(Export.new(user: @user, exported_at: at).call)
        second = JSON.generate(Export.new(user: @user, exported_at: at).call)

        assert_equal first, second
      end

      test "transactions are exported in executed_on order" do
        buy!(@portfolio, @aapl, on: Date.new(2024, 3, 5), shares: "1", price: "100")
        buy!(@portfolio, @aapl, on: Date.new(2024, 1, 5), shares: "1", price: "100")
        buy!(@portfolio, @aapl, on: Date.new(2024, 2, 5), shares: "1", price: "100")

        dates = envelope[:portfolios].first[:transactions].map { |t| t[:executed_on] }
        assert_equal dates.sort, dates
      end

      # --- Query budget ---

      test "does not N+1 over transactions' instruments" do
        5.times { |i| buy!(@portfolio, @aapl, on: Date.new(2024, 1, 5 + i), shares: "1", price: "100") }
        create_portfolio(name: "Second", user: @user).then do |second|
          3.times { |i| buy!(second, @aapl, on: Date.new(2024, 2, 5 + i), shares: "1", price: "100") }
        end

        queries = count_queries { Export.new(user: @user).call }

        # portfolios + benchmarks + transactions + instruments + recurring (+ its
        # instruments) — a fixed handful, independent of row count.
        assert_operator queries, :<=, 8, "export must preload, not query per row"
      end
    end
  end
end
