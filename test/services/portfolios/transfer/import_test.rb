require "test_helper"

# backlog #064: writing a Document into a user's account.
module Portfolios
  module Transfer
    class ImportTest < ActiveSupport::TestCase
      include DomainTestHelper
      include ActiveJob::TestHelper

      setup do
        @user = users(:one)
        @other_user = users(:two)
      end

      # --- Builders ------------------------------------------------------------

      def instrument_spec(symbol, **overrides)
        InstrumentSpec.build(**{ symbol: symbol, name: "#{symbol} Inc", instrument_type: "stock",
                                 currency: "USD" }.merge(overrides))
      end

      def transaction_spec(symbol, side: "buy", shares: "10", price: "100", on: "2024-01-05", **overrides)
        TransactionSpec.new(**{
          symbol: symbol, side: side, kind: "normal", shares: bd(shares), price: bd(price),
          fees: bd("0"), executed_on: on.is_a?(Date) ? on : Date.parse(on), notes: nil,
          recurring_key: nil, scheduled_for: nil
        }.merge(overrides))
      end

      def recurring_spec(symbol, key: "r1", **overrides)
        RecurringSpec.new(**{
          key: key, symbol: symbol, side: "buy", amount_type: "dollars", dollar_amount: bd("100"),
          share_amount: nil, frequency: "monthly", anchor_on: Date.new(2124, 1, 31),
          next_run_on: Date.new(2124, 1, 31), end_on: nil, active: true
        }.merge(overrides))
      end

      def portfolio_spec(name, transactions: [], recurring: [], benchmark: nil)
        PortfolioSpec.new(name: name, benchmark_name: benchmark, transactions: transactions,
                          recurring_transactions: recurring, warnings: [])
      end

      def document(portfolios:, instruments: [], format: NATIVE_FORMAT, warnings: [])
        Document.new(format: format, instruments: instruments, portfolios: portfolios, warnings: warnings)
      end

      def import(doc, **kwargs) = Import.call(user: @user, document: doc, **kwargs)

      def one_portfolio_doc(**kwargs)
        document(instruments: [ instrument_spec("AAPL") ],
                 portfolios: [ portfolio_spec("Retirement", **kwargs) ])
      end

      # --- Happy path ----------------------------------------------------------

      test "creates the portfolio, its transactions and its rules" do
        doc = one_portfolio_doc(
          transactions: [ transaction_spec("AAPL", shares: "10", price: "150.25") ],
          recurring: [ recurring_spec("AAPL") ]
        )

        result = import(doc)

        assert_equal "created", result.portfolios.first.status
        assert_equal 1, result.totals[:transactions_created]
        assert_equal 1, result.totals[:recurring_created]

        portfolio = @user.portfolios.find_by!(name: "Retirement")
        transaction = portfolio.transactions.sole
        assert_equal bd("10"), transaction.shares
        assert_equal bd("150.25"), transaction.price
        assert_equal "AAPL", transaction.instrument.symbol
      end

      test "attaches a benchmark by name" do
        ::Benchmark.create!(instrument: create_instrument(symbol: "SPY", instrument_type: "etf"),
                            name: "S&P 500 (SPY)")

        result = import(one_portfolio_doc(benchmark: "S&P 500 (SPY)"))

        assert_equal "S&P 500 (SPY)", @user.portfolios.sole.benchmark.name
        assert_empty result.portfolios.first.warnings
      end

      test "a benchmark absent from this database warns but still imports the portfolio" do
        result = import(one_portfolio_doc(benchmark: "Nikkei 225 (EWJ)"))

        assert_equal "created", result.portfolios.first.status
        assert_nil @user.portfolios.sole.benchmark
        assert result.portfolios.first.warnings.any? { |w| w.include?("Nikkei 225 (EWJ)") },
               "a dropped benchmark must be reported, not silent"
      end

      test "imports into the CURRENT user, never another one" do
        import(one_portfolio_doc)

        assert_equal 1, @user.portfolios.count
        assert_equal 0, @other_user.portfolios.count
      end

      # --- Instrument resolution ----------------------------------------------

      test "creates an instrument from the file's identity, including a non-US listing" do
        doc = document(
          instruments: [ instrument_spec("ZEQT.TO", name: "BMO All-Equity ETF",
                                         instrument_type: "etf", currency: "CAD") ],
          portfolios: [ portfolio_spec("TFSA", transactions: [ transaction_spec("ZEQT.TO") ]) ]
        )

        import(doc)

        instrument = Instrument.find_by!("upper(symbol) = ?", "ZEQT.TO")
        assert_equal "CAD", instrument.currency
        assert_equal "etf", instrument.instrument_type
        assert_equal "BMO All-Equity ETF", instrument.name
      end

      test "a venue-suffixed symbol does NOT collide with the bare US ticker" do
        us_meta = Instrument.create!(symbol: "META", instrument_type: "stock", currency: "USD")
        doc = document(
          instruments: [ instrument_spec("META.TO", name: "Meta CDR (CAD Hedged)", currency: "CAD") ],
          portfolios: [ portfolio_spec("TFSA", transactions: [ transaction_spec("META.TO") ]) ]
        )

        import(doc)

        cdr = Instrument.find_by!("upper(symbol) = ?", "META.TO")
        assert_not_equal us_meta.id, cdr.id, "the CDR must be its own instrument"
        assert_equal "CAD", cdr.currency
        assert_equal "USD", us_meta.reload.currency, "the US row must be untouched"
      end

      test "an existing instrument is reused and never rewritten from the file" do
        existing = Instrument.create!(symbol: "AAPL", name: "Apple Inc.", instrument_type: "stock",
                                      currency: "USD", sector: "Technology")
        doc = document(
          instruments: [ instrument_spec("AAPL", name: "WRONG", instrument_type: "etf", currency: "EUR") ],
          portfolios: [ portfolio_spec("P", transactions: [ transaction_spec("AAPL") ]) ]
        )

        assert_no_difference("Instrument.count") { import(doc) }

        existing.reload
        assert_equal "Apple Inc.", existing.name, "an import must not downgrade local provider metadata"
        assert_equal "USD", existing.currency
        assert_equal "Technology", existing.sector
      end

      test "a symbol with no file identity falls back to the directory rules" do
        ListedInstrument.create!(symbol: "MSFT", exchange: "NASDAQ", currency: "USD", asset_type: "Stock")
        doc = document(instruments: [], portfolios: [
          portfolio_spec("P", transactions: [ transaction_spec("MSFT") ])
        ])

        result = import(doc)

        assert_equal "created", result.portfolios.first.status
        assert Instrument.exists?([ "upper(symbol) = ?", "MSFT" ])
      end

      test "an unknown symbol with no file identity fails its portfolio with a clear reason" do
        doc = document(instruments: [], portfolios: [
          portfolio_spec("P", transactions: [ transaction_spec("NOPE") ])
        ])

        result = import(doc)

        assert_equal "failed", result.portfolios.first.status
        assert_match(/NOPE/, result.portfolios.first.errors.first)
        assert_match(/carries no instrument details/, result.portfolios.first.errors.first)
        assert_equal 0, @user.portfolios.count
      end

      # --- Provider-quota suppression -----------------------------------------

      test "does not enqueue provider jobs for a symbol the directory does not list" do
        ListedInstrument.create!(symbol: "AAPL", exchange: "NASDAQ", currency: "USD", asset_type: "Stock")
        doc = document(
          instruments: [ instrument_spec("ZEQT.TO", currency: "CAD") ],
          portfolios: [ portfolio_spec("TFSA", transactions: [ transaction_spec("ZEQT.TO") ]) ]
        )

        # Tiingo has zero non-US coverage, so a backfill here would spend a slot of
        # the scarce MONTHLY UNIQUE-SYMBOL budget to learn nothing.
        assert_no_enqueued_jobs only: [ Prices::BackfillInstrumentJob, Instruments::MetadataJob ] do
          import(doc)
        end
      end

      test "DOES enqueue provider jobs for a symbol the directory lists" do
        ListedInstrument.create!(symbol: "MSFT", exchange: "NASDAQ", currency: "USD", asset_type: "Stock")
        doc = document(
          instruments: [ instrument_spec("MSFT") ],
          portfolios: [ portfolio_spec("P", transactions: [ transaction_spec("MSFT") ]) ]
        )

        assert_enqueued_with job: Prices::BackfillInstrumentJob do
          import(doc)
        end
      end

      test "an EMPTY directory stays permissive so a rebuilt database still backfills" do
        # The headline use case for this feature is restoring into a fresh database,
        # where Directory::ImportJob may not have run yet. Suppressing there would
        # leave every imported instrument permanently un-backfilled.
        assert_equal 0, ListedInstrument.count
        doc = document(
          instruments: [ instrument_spec("MSFT") ],
          portfolios: [ portfolio_spec("P", transactions: [ transaction_spec("MSFT") ]) ]
        )

        assert_enqueued_with job: Prices::BackfillInstrumentJob do
          import(doc)
        end
      end

      # --- Ordering vs the no-short-positions guard ----------------------------

      test "a sell listed BEFORE its covering buy still imports (rows are date-ordered)" do
        doc = one_portfolio_doc(transactions: [
          transaction_spec("AAPL", side: "sell", shares: "5", on: "2024-06-01"),
          transaction_spec("AAPL", side: "buy",  shares: "10", on: "2024-01-05")
        ])

        result = import(doc)

        assert_equal "created", result.portfolios.first.status, result.portfolios.first.errors.inspect
        assert_equal 2, result.totals[:transactions_created]
      end

      test "a same-day buy and sell import in either file order" do
        doc = one_portfolio_doc(transactions: [
          transaction_spec("AAPL", side: "sell", shares: "10", on: "2024-01-05"),
          transaction_spec("AAPL", side: "buy",  shares: "10", on: "2024-01-05")
        ])

        result = import(doc)

        assert_equal "created", result.portfolios.first.status, result.portfolios.first.errors.inspect
      end

      test "a genuine oversell fails the portfolio and names the offending date" do
        doc = one_portfolio_doc(transactions: [
          transaction_spec("AAPL", side: "buy",  shares: "5",  on: "2024-01-05"),
          transaction_spec("AAPL", side: "sell", shares: "10", on: "2024-02-05")
        ])

        result = import(doc)

        assert_equal "failed", result.portfolios.first.status
        assert_match(/2024-02-05/, result.portfolios.first.errors.first)
      end

      # --- Per-portfolio atomicity --------------------------------------------

      test "a failed portfolio is rolled back WHOLE, never left half-imported" do
        doc = document(instruments: [ instrument_spec("AAPL") ], portfolios: [
          portfolio_spec("Bad", transactions: [
            transaction_spec("AAPL", shares: "10", on: "2024-01-05"),
            transaction_spec("AAPL", side: "sell", shares: "99", on: "2024-02-05")
          ])
        ])

        result = import(doc)

        assert_equal "failed", result.portfolios.first.status
        assert_equal 0, @user.portfolios.count, "no portfolio row may survive"
        assert_equal 0, Transaction.count, "the valid first transaction must roll back too"
      end

      test "one failed portfolio does not discard its healthy siblings" do
        doc = document(instruments: [ instrument_spec("AAPL") ], portfolios: [
          portfolio_spec("Good One", transactions: [ transaction_spec("AAPL") ]),
          portfolio_spec("Bad", transactions: [ transaction_spec("AAPL", side: "sell", shares: "1") ]),
          portfolio_spec("Good Two", transactions: [ transaction_spec("AAPL") ])
        ])

        result = import(doc)

        assert_equal %w[created failed created], result.portfolios.map(&:status)
        assert_equal 2, result.totals[:portfolios_created]
        assert_equal 1, result.totals[:portfolios_failed]
        assert_equal [ "Good One", "Good Two" ], @user.portfolios.order(:name).pluck(:name)
      end

      test "an instrument created for a failing portfolio survives for a later one" do
        # A later portfolio referencing the same symbol still resolves it. NOTE:
        # this passes even WITHOUT phase 2 — Rails nils the id of a record created
        # in a rolled-back savepoint, so the cached Instrument goes back to
        # new_record? and belongs_to autosave re-INSERTs it. The test below is the
        # one that actually discriminates.
        doc = document(instruments: [ instrument_spec("NEWCO") ], portfolios: [
          portfolio_spec("Bad", transactions: [ transaction_spec("NEWCO", side: "sell", shares: "1") ]),
          portfolio_spec("Good", transactions: [ transaction_spec("NEWCO", side: "buy", shares: "1") ])
        ])

        result = import(doc)

        assert_equal %w[failed created], result.portfolios.map(&:status)
        transaction = @user.portfolios.find_by!(name: "Good").transactions.sole
        assert_equal "NEWCO", transaction.instrument.symbol
        assert Instrument.exists?(transaction.instrument_id)
      end

      test "an instrument is resolved in the OUTER transaction, so it survives its only portfolio failing" do
        # THE phase-2 regression guard. Nothing re-creates the instrument here,
        # because the ONLY portfolio referencing NEWCO fails — so the row exists
        # afterwards if and only if it was created outside that savepoint.
        doc = document(instruments: [ instrument_spec("NEWCO") ], portfolios: [
          portfolio_spec("Bad", transactions: [ transaction_spec("NEWCO", side: "sell", shares: "1") ])
        ])

        result = import(doc)

        assert_equal [ "failed" ], result.portfolios.map(&:status)
        assert Instrument.exists?([ "upper(symbol) = ?", "NEWCO" ]),
               "instruments must be resolved in the OUTER transaction, so a portfolio's " \
               "savepoint rollback cannot orphan the resolver cache"
      end

      # --- Name conflicts: never destructive ----------------------------------

      test "renames on a name collision by default and reports the new name" do
        create_portfolio(name: "Retirement", user: @user)

        result = import(one_portfolio_doc(transactions: [ transaction_spec("AAPL") ]))

        row = result.portfolios.first
        assert_equal "renamed", row.status
        assert_equal "Retirement", row.name
        assert_equal "Retirement (imported)", row.imported_as
        assert row.warnings.any? { |w| w.include?("Retirement (imported)") }
        assert_equal 0, Portfolio.find_by!(name: "Retirement").transactions.count,
                      "the pre-existing portfolio must be untouched"
      end

      test "renaming escalates past an existing (imported) name" do
        create_portfolio(name: "Retirement", user: @user)
        create_portfolio(name: "Retirement (imported)", user: @user)

        result = import(one_portfolio_doc)

        assert_equal "Retirement (imported 2)", result.portfolios.first.imported_as
      end

      test "on_conflict skip leaves the existing portfolio alone and imports nothing" do
        existing = create_portfolio(name: "Retirement", user: @user)

        result = import(one_portfolio_doc(transactions: [ transaction_spec("AAPL") ]),
                        on_conflict: "skip")

        assert_equal "skipped", result.portfolios.first.status
        assert_equal 1, result.totals[:portfolios_skipped]
        assert_equal 0, result.totals[:transactions_created]
        assert_equal 1, @user.portfolios.count
        assert_equal 0, existing.transactions.count
      end

      test "two identically named portfolios in ONE file both land" do
        # The unique index only sees committed rows, so an in-run claim set is
        # needed as well.
        doc = document(instruments: [ instrument_spec("AAPL") ], portfolios: [
          portfolio_spec("TFSA", transactions: [ transaction_spec("AAPL") ]),
          portfolio_spec("TFSA", transactions: [ transaction_spec("AAPL") ])
        ])

        result = import(doc)

        assert_equal %w[created renamed], result.portfolios.map(&:status)
        assert_equal [ "TFSA", "TFSA (imported)" ], @user.portfolios.order(:name).pluck(:name)
      end

      test "another user's identical portfolio name is not a conflict" do
        create_portfolio(name: "Retirement", user: @other_user)

        result = import(one_portfolio_doc)

        assert_equal "created", result.portfolios.first.status
        assert_equal "Retirement", result.portfolios.first.imported_as
      end

      test "an unknown on_conflict value falls back to rename rather than erroring" do
        create_portfolio(name: "Retirement", user: @user)

        result = import(one_portfolio_doc, on_conflict: "obliterate")

        assert_equal "renamed", result.portfolios.first.status
      end

      # --- Recurring linkage ---------------------------------------------------

      test "relinks a materialized transaction to its rule via the file-local key" do
        doc = document(instruments: [ instrument_spec("AAPL") ], portfolios: [
          portfolio_spec("P",
                         recurring: [ recurring_spec("AAPL", key: "r1") ],
                         transactions: [ transaction_spec("AAPL", recurring_key: "r1",
                                                          scheduled_for: Date.new(2024, 1, 31)) ])
        ])

        import(doc)

        transaction = @user.portfolios.sole.transactions.sole
        assert_equal @user.portfolios.sole.recurring_transactions.sole.id,
                     transaction.recurring_transaction_id
        assert_equal Date.new(2024, 1, 31), transaction.scheduled_for,
                     "scheduled_for is the materialization idempotency guard and must survive"
      end

      test "a dangling recurring key imports the transaction standalone and warns" do
        doc = one_portfolio_doc(transactions: [ transaction_spec("AAPL", recurring_key: "r9") ])

        result = import(doc)

        transaction = @user.portfolios.sole.transactions.sole
        assert_nil transaction.recurring_transaction_id
        assert_nil transaction.scheduled_for
        assert result.portfolios.first.warnings.any? { |w| w.include?("r9") }
      end

      test "a rule whose next_run_on is in the past is clamped forward AND reported" do
        doc = document(instruments: [ instrument_spec("AAPL") ], portfolios: [
          portfolio_spec("P", recurring: [ recurring_spec("AAPL",
                                                          anchor_on: Date.new(2020, 1, 15),
                                                          next_run_on: Date.new(2020, 2, 15)) ])
        ])

        result = import(doc)

        rule = @user.portfolios.sole.recurring_transactions.sole
        assert_operator rule.next_run_on, :>=, Trading::Calendar.today,
                        "an import must not schedule months of back-materialization"
        assert result.portfolios.first.warnings.any? { |w| w.include?("next run is moved from 2020-02-15") },
               "silently moving the schedule would misrepresent the file"
      end

      test "an invalid rule fails its portfolio with the model's own message" do
        doc = document(instruments: [ instrument_spec("AAPL") ], portfolios: [
          portfolio_spec("P", recurring: [ recurring_spec("AAPL", frequency: "hourly") ])
        ])

        result = import(doc)

        assert_equal "failed", result.portfolios.first.status
        assert_match(/[Ff]requency/, result.portfolios.first.errors.first)
      end

      # --- Dry run -------------------------------------------------------------

      test "a dry run reports exactly what would happen and writes nothing" do
        doc = document(instruments: [ instrument_spec("AAPL") ], portfolios: [
          portfolio_spec("Good", transactions: [ transaction_spec("AAPL") ]),
          portfolio_spec("Bad", transactions: [ transaction_spec("AAPL", side: "sell", shares: "1") ])
        ])

        result = nil
        assert_no_difference [ "Portfolio.count", "Transaction.count", "Instrument.count" ] do
          result = import(doc, dry_run: true)
        end

        assert result.dry_run
        assert_equal %w[created failed], result.portfolios.map(&:status),
                     "the preview must agree with the real run, including the failure"
        assert_equal 1, result.totals[:transactions_created]
      end

      test "a dry run enqueues no provider jobs" do
        doc = one_portfolio_doc(transactions: [ transaction_spec("AAPL") ])

        assert_no_enqueued_jobs only: [ Prices::BackfillInstrumentJob, Instruments::MetadataJob ] do
          import(doc, dry_run: true)
        end
      end

      test "no warning claims a completed write, because previews reuse these strings" do
        # Caught on screen, not by an assertion: the preview showed "so this one
        # WAS IMPORTED as ..." for a rename, telling users their data had already
        # been written when nothing had. The same strings serve both modes, so the
        # wording must stay tense-neutral.
        create_portfolio(name: "Retirement", user: @user)
        ListedInstrument.create!(symbol: "AAPL", exchange: "NASDAQ", currency: "USD", asset_type: "Stock")

        doc = document(instruments: [ instrument_spec("AAPL") ], portfolios: [
          portfolio_spec("Retirement", benchmark: "Nikkei 225 (EWJ)",
                         transactions: [ transaction_spec("AAPL", recurring_key: "gone") ],
                         recurring: [ recurring_spec("AAPL", anchor_on: Date.new(2020, 1, 15),
                                                     next_run_on: Date.new(2020, 2, 15)) ])
        ])

        warnings = import(doc, dry_run: true).portfolios.flat_map(&:warnings)

        assert_not_empty warnings, "this fixture must actually produce warnings or the test is vacuous"
        warnings.each do |warning|
          assert_no_match(/\b(was|were)\s+imported\b/i, warning,
                          "a preview must not claim the write already happened: #{warning.inspect}")
        end
      end

      test "a dry run followed by a real run produces the same outcome" do
        doc = one_portfolio_doc(transactions: [ transaction_spec("AAPL") ])

        preview = import(doc, dry_run: true)
        real = import(doc)

        assert_equal preview.portfolios.map(&:status), real.portfolios.map(&:status)
        assert_equal preview.totals.except(:portfolios_created), real.totals.except(:portfolios_created)
        assert_equal preview.portfolios.first.imported_as, real.portfolios.first.imported_as
      end

      # --- Reporting -----------------------------------------------------------

      test "file-level warnings from the parser are carried into the result" do
        doc = document(instruments: [], portfolios: [], warnings: [ "the report had no As of date" ])

        assert_equal [ "the report had no As of date" ], import(doc).warnings
      end

      test "an empty document is a no-op, not an error" do
        result = import(document(portfolios: []))

        assert_empty result.portfolios
        assert_equal 0, result.totals[:portfolios_created]
      end

      test "totals reconcile with the per-portfolio rows" do
        doc = document(instruments: [ instrument_spec("AAPL") ], portfolios: [
          portfolio_spec("A", transactions: [ transaction_spec("AAPL"), transaction_spec("AAPL") ]),
          portfolio_spec("B", recurring: [ recurring_spec("AAPL") ])
        ])

        result = import(doc)

        assert_equal result.portfolios.sum(&:transactions_created), result.totals[:transactions_created]
        assert_equal result.portfolios.sum(&:recurring_created), result.totals[:recurring_created]
        assert_equal 2, result.totals[:transactions_created]
        assert_equal 1, result.totals[:recurring_created]
      end
      # --- #79: changing the venue default must not split one security in two ---

      # THE CRITERION THAT MATTERS MOST, and it is asserted against a database
      # that ALREADY HOLDS THE OLD SPELLING rather than a fresh one. #79 changes
      # what a venue-less broker row resolves to (FINN -> FINN.NE instead of
      # FINN.TO), and `instruments` is UNIQUE on upper(symbol) alone — so for a
      # user who imported before the change, the new spelling must reuse the
      # existing row, not mint a sibling with half the history. Two half-sized
      # positions on a dashboard read as data, not as an error.
      test "a venue-suffix change reuses the instrument imported under the old spelling" do
        old = Instrument.create!(symbol: "FINN.TO", name: "Fidelity Global Innovators ETF",
                                 instrument_type: "etf", currency: "CAD")

        doc = document(
          instruments: [ instrument_spec("FINN.NE", name: "Fidelity Global Innovators ETF",
                                         instrument_type: "etf", currency: "CAD") ],
          portfolios: [ portfolio_spec("CAD", transactions: [ transaction_spec("FINN.NE") ]) ]
        )

        result = nil
        assert_no_difference -> { Instrument.count } do
          result = import(doc)
        end
        assert_equal "created", result.portfolios.first.status

        assert_equal old.id, Transaction.order(:id).last.instrument_id,
                     "the new spelling must bind to the instrument already stored"
      end

      test "the sibling reuse does NOT collapse a US ticker into a non-US listing" do
        # The other direction, and the reason venue_sibling_for requires BOTH
        # sides to be venue-suffixed. US FINN and Canadian FINN.NE are different
        # securities and must stay different instruments.
        us = Instrument.create!(symbol: "FINN", name: "US Finn", instrument_type: "stock",
                                currency: "USD")

        doc = document(
          instruments: [ instrument_spec("FINN.NE", name: "Fidelity Global Innovators ETF",
                                         instrument_type: "etf", currency: "CAD") ],
          portfolios: [ portfolio_spec("CAD", transactions: [ transaction_spec("FINN.NE") ]) ]
        )

        result = nil
        assert_difference -> { Instrument.count }, 1 do
          result = import(doc)
        end
        assert_equal "created", result.portfolios.first.status

        assert_not_equal us.id, Transaction.order(:id).last.instrument_id
      end

      test "a DIFFERENT currency under the same base is not treated as a sibling" do
        # venue_sibling_for matches on base symbol AND currency. A USD-quoted
        # non-US listing is not the same security as the CAD one.
        Instrument.create!(symbol: "XYZ.TO", name: "XYZ USD line", instrument_type: "etf",
                           currency: "USD")

        doc = document(
          instruments: [ instrument_spec("XYZ.NE", name: "XYZ CAD line", instrument_type: "etf",
                                         currency: "CAD") ],
          portfolios: [ portfolio_spec("CAD", transactions: [ transaction_spec("XYZ.NE") ]) ]
        )

        result = nil
        assert_difference -> { Instrument.count }, 1 do
          result = import(doc)
        end
        assert_equal "created", result.portfolios.first.status
      end
    end
  end
end
