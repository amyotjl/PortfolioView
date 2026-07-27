require "test_helper"

# backlog #068: importing instrument-global corporate actions, and keeping one
# security from splitting across two venue-suffixed instruments.
module Portfolios
  module Transfer
    class ImportSplitsTest < ActiveSupport::TestCase
      include DomainTestHelper

      setup do
        @user = users(:one)
      end

      def instrument_spec(symbol, **overrides)
        InstrumentSpec.build(**{ symbol: symbol, name: "#{symbol} Fund", instrument_type: "etf",
                                 currency: "CAD" }.merge(overrides))
      end

      def transaction_spec(symbol, side: "buy", shares: "10", price: "20", on: "2025-01-02")
        TransactionSpec.new(
          symbol: symbol, side: side, kind: "normal", shares: bd(shares), price: bd(price),
          fees: bd("0"), executed_on: Date.parse(on), notes: nil,
          recurring_key: nil, scheduled_for: nil
        )
      end

      def document(portfolios:, instruments: [], splits: [])
        Document.new(format: ACTIVITIES_CSV_FORMAT, instruments: instruments,
                     portfolios: portfolios, warnings: [], splits: splits)
      end

      def portfolio_spec(name, transactions)
        PortfolioSpec.new(name: name, benchmark_name: nil, transactions: transactions,
                          recurring_transactions: [], warnings: [])
      end

      def import(doc, **kwargs) = Import.call(user: @user, document: doc, **kwargs)

      # --- The split lands, and it lands FIRST ---------------------------------

      test "creates the split event and counts it in the totals" do
        doc = document(
          instruments: [ instrument_spec("ZEQT.TO") ],
          portfolios: [ portfolio_spec("TFSA", [ transaction_spec("ZEQT.TO") ]) ],
          splits: [ SplitSpec.new(symbol: "ZEQT.TO", ex_date: Date.new(2025, 6, 1), ratio: bd("3")) ]
        )

        result = import(doc)

        assert_equal 1, result.totals[:splits_created]
        instrument = Instrument.find_by!("upper(symbol) = ?", "ZEQT.TO")
        event = SplitEvent.find_by!(instrument_id: instrument.id, ex_date: Date.new(2025, 6, 1))
        assert_equal bd("3"), event.ratio
      end

      test "a sell of POST-split shares is accepted, which only works if the split is written first" do
        # Positions::Validator replays against the splits in the DATABASE. Buy 10,
        # split 3:1 -> 30, sell 25. Without the split committed before the
        # transactions, the replay sees 10 shares and rejects the sell as an
        # oversell — and the whole portfolio would fail.
        doc = document(
          instruments: [ instrument_spec("ZEQT.TO") ],
          portfolios: [ portfolio_spec("TFSA", [
            transaction_spec("ZEQT.TO", shares: "10", on: "2025-01-02"),
            transaction_spec("ZEQT.TO", side: "sell", shares: "25", on: "2025-07-01")
          ]) ],
          splits: [ SplitSpec.new(symbol: "ZEQT.TO", ex_date: Date.new(2025, 6, 1), ratio: bd("3")) ]
        )

        result = import(doc)

        assert_equal "created", result.portfolios.first.status, result.portfolios.first.errors.inspect
        assert_equal 2, result.totals[:transactions_created]
      end

      test "without the split that same sell is correctly rejected" do
        # Non-vacuity for the test above: the sell is only legal BECAUSE of the split.
        doc = document(
          instruments: [ instrument_spec("ZEQT.TO") ],
          portfolios: [ portfolio_spec("TFSA", [
            transaction_spec("ZEQT.TO", shares: "10", on: "2025-01-02"),
            transaction_spec("ZEQT.TO", side: "sell", shares: "25", on: "2025-07-01")
          ]) ],
          splits: []
        )

        result = import(doc)

        assert_equal "failed", result.portfolios.first.status
        assert_match(/2025-07-01/, result.portfolios.first.errors.first)
      end

      test "the split applies to every portfolio holding the instrument" do
        # That is what instrument-global means, and why the event is written
        # outside any per-portfolio savepoint.
        create_trading_days(Date.new(2025, 1, 1), Date.new(2025, 12, 31))
        doc = document(
          instruments: [ instrument_spec("ZEQT.TO") ],
          portfolios: [
            portfolio_spec("TFSA", [ transaction_spec("ZEQT.TO", shares: "10", on: "2025-01-02") ]),
            portfolio_spec("RRSP", [ transaction_spec("ZEQT.TO", shares: "4", on: "2025-01-02") ])
          ],
          splits: [ SplitSpec.new(symbol: "ZEQT.TO", ex_date: Date.new(2025, 6, 2), ratio: bd("3")) ]
        )

        import(doc)

        instrument = Instrument.find_by!("upper(symbol) = ?", "ZEQT.TO")
        %w[TFSA RRSP].zip([ bd("30"), bd("12") ]).each do |name, expected|
          portfolio = @user.portfolios.find_by!(name: name)
          holdings = Holdings::Calculator.call(portfolio: portfolio,
                                               from: Date.new(2025, 12, 1), to: Date.new(2025, 12, 31)).holdings
          assert_equal expected, holdings.values.last[instrument.id],
                       "#{name} should hold post-split shares"
        end
      end

      # --- Never overwrite market data ----------------------------------------

      test "an existing split for the same instrument and date is not overwritten" do
        instrument = Instrument.create!(symbol: "ZEQT.TO", instrument_type: "etf", currency: "CAD",
                                        skip_provider_jobs: true)
        SplitEvent.create!(instrument: instrument, ex_date: Date.new(2025, 6, 1), ratio: bd("2"))

        doc = document(
          instruments: [ instrument_spec("ZEQT.TO") ],
          portfolios: [ portfolio_spec("TFSA", [ transaction_spec("ZEQT.TO") ]) ],
          splits: [ SplitSpec.new(symbol: "ZEQT.TO", ex_date: Date.new(2025, 6, 1), ratio: bd("3")) ]
        )

        result = import(doc)

        assert_equal bd("2"), SplitEvent.find_by!(instrument_id: instrument.id,
                                                  ex_date: Date.new(2025, 6, 1)).ratio
        assert_equal 0, result.totals[:splits_created]
        assert result.warnings.any? { |w| w.include?("existing market data wins") },
               "a rejected split must be reported, got: #{result.warnings.inspect}"
      end

      test "re-importing the same file twice creates the split only once" do
        doc = document(
          instruments: [ instrument_spec("ZEQT.TO") ],
          portfolios: [ portfolio_spec("TFSA", [ transaction_spec("ZEQT.TO") ]) ],
          splits: [ SplitSpec.new(symbol: "ZEQT.TO", ex_date: Date.new(2025, 6, 1), ratio: bd("3")) ]
        )

        assert_equal 1, import(doc).totals[:splits_created]
        assert_equal 0, import(doc).totals[:splits_created], "the second run is idempotent"
        assert_equal 1, SplitEvent.where(ex_date: Date.new(2025, 6, 1)).count
      end

      test "a split whose symbol cannot be resolved is reported, not raised" do
        doc = document(
          instruments: [],
          portfolios: [],
          splits: [ SplitSpec.new(symbol: "NOPE.TO", ex_date: Date.new(2025, 6, 1), ratio: bd("3")) ]
        )

        result = import(doc)

        assert_equal 0, result.totals[:splits_created]
        assert result.warnings.any? { |w| w.include?("NOPE.TO") }
      end

      test "a dry run writes no split event" do
        doc = document(
          instruments: [ instrument_spec("ZEQT.TO") ],
          portfolios: [ portfolio_spec("TFSA", [ transaction_spec("ZEQT.TO") ]) ],
          splits: [ SplitSpec.new(symbol: "ZEQT.TO", ex_date: Date.new(2025, 6, 1), ratio: bd("3")) ]
        )

        result = nil
        assert_no_difference "SplitEvent.count" do
          result = import(doc, dry_run: true)
        end

        assert_equal 1, result.totals[:splits_created], "the preview still reports what it would do"
      end

      # --- Cross-format venue aliasing ----------------------------------------

      test "reuses an existing venue sibling instead of minting a second instrument" do
        # The holdings report carries a MIC and yields FINN.NE; the activity ledger
        # has no exchange column and would mint FINN.TO. One security, two
        # instruments, each with half the history — which reads as two half-sized
        # positions rather than as an error.
        existing = Instrument.create!(symbol: "FINN.NE", name: "Fidelity Global Innovators",
                                      instrument_type: "etf", currency: "CAD", skip_provider_jobs: true)

        doc = document(
          instruments: [ instrument_spec("FINN.TO") ],
          portfolios: [ portfolio_spec("TFSA", [ transaction_spec("FINN.TO") ]) ]
        )

        assert_no_difference("Instrument.count") { import(doc) }

        assert_equal existing.id, @user.portfolios.sole.transactions.sole.instrument_id
      end

      test "aliasing is symmetric — whichever file is imported first wins the name" do
        existing = Instrument.create!(symbol: "FINN.TO", instrument_type: "etf", currency: "CAD",
                                      skip_provider_jobs: true)

        doc = document(
          instruments: [ instrument_spec("FINN.NE") ],
          portfolios: [ portfolio_spec("TFSA", [ transaction_spec("FINN.NE") ]) ]
        )

        assert_no_difference("Instrument.count") { import(doc) }

        assert_equal existing.id, @user.portfolios.sole.transactions.sole.instrument_id
      end

      test "aliasing NEVER collapses a non-US listing into the US ticker" do
        # This is the collision SymbolQualifier exists to prevent: META.TO is a
        # CAD-hedged CDR, a different security from NASDAQ's META.
        us = Instrument.create!(symbol: "META", instrument_type: "stock", currency: "USD")

        doc = document(
          instruments: [ instrument_spec("META.TO", instrument_type: "stock") ],
          portfolios: [ portfolio_spec("TFSA", [ transaction_spec("META.TO") ]) ]
        )

        import(doc)

        cdr = @user.portfolios.sole.transactions.sole.instrument
        assert_not_equal us.id, cdr.id
        assert_equal "META.TO", cdr.symbol
        assert_equal "USD", us.reload.currency
      end

      test "aliasing does not match across currencies" do
        # A USD-quoted foreign listing and a CAD one are different securities.
        Instrument.create!(symbol: "ABC.L", instrument_type: "stock", currency: "GBP",
                           skip_provider_jobs: true)

        doc = document(
          instruments: [ instrument_spec("ABC.TO", instrument_type: "stock", currency: "CAD") ],
          portfolios: [ portfolio_spec("TFSA", [ transaction_spec("ABC.TO") ]) ]
        )

        assert_difference("Instrument.count", 1) { import(doc) }

        assert_equal "ABC.TO", @user.portfolios.sole.transactions.sole.instrument.symbol
      end

      test "a share-class base is not confused with a different security" do
        # HPS.A.TO and HPS.TO share no base once the venue suffix is removed
        # ("HPS.A" vs "HPS"), so they must stay separate instruments.
        Instrument.create!(symbol: "HPS.TO", instrument_type: "stock", currency: "CAD",
                           skip_provider_jobs: true)

        doc = document(
          instruments: [ instrument_spec("HPS.A.TO", instrument_type: "stock") ],
          portfolios: [ portfolio_spec("TFSA", [ transaction_spec("HPS.A.TO") ]) ]
        )

        assert_difference("Instrument.count", 1) { import(doc) }

        assert_equal "HPS.A.TO", @user.portfolios.sole.transactions.sole.instrument.symbol
      end

      test "an unsuffixed symbol never aliases onto a suffixed one" do
        Instrument.create!(symbol: "QQQ.TO", instrument_type: "etf", currency: "CAD",
                           skip_provider_jobs: true)
        ListedInstrument.create!(symbol: "QQQ", exchange: "NASDAQ", currency: "USD", asset_type: "ETF")

        doc = document(
          instruments: [ instrument_spec("QQQ", instrument_type: "etf", currency: "USD") ],
          portfolios: [ portfolio_spec("TFSA", [ transaction_spec("QQQ") ]) ]
        )

        assert_difference("Instrument.count", 1) { import(doc) }

        assert_equal "QQQ", @user.portfolios.sole.transactions.sole.instrument.symbol
      end
    end
  end
end
