require "test_helper"

# backlog #064: broker holdings-snapshot CSV -> Document.
#
# The fixture (test/fixtures/files/holdings_report.csv) mirrors the real
# Wealthsimple report shape and deliberately packs in every awkward case the
# real file contains: a CDR whose ticker collides with a US listing, a symbol the
# broker already venue-suffixed, a 24-decimal book value, a short position, a
# closed (zero-quantity) position, and a USD/US row alongside the CAD ones.
module Portfolios
  module Transfer
    class HoldingsCsvParserTest < ActiveSupport::TestCase
      setup do
        @body = file_fixture("holdings_report.csv").read
        @document = HoldingsCsvParser.call(@body)
      end

      def portfolio(name) = @document.portfolios.find { |p| p.name == name }
      def transaction(portfolio_name, symbol)
        portfolio(portfolio_name).transactions.find { |t| t.symbol == symbol }
      end

      # --- Shape ---

      test "groups rows into one portfolio per account name" do
        assert_equal %w[RRSP TFSA], @document.portfolios.map(&:name).sort
        assert_equal HOLDINGS_CSV_FORMAT, @document.format
      end

      test "detector routes this file to this parser" do
        assert_equal HoldingsCsvParser, Detector.new(@body).parser
      end

      # --- Cost basis: the reason book value is divided rather than market price used ---

      test "derives price from book value so total cost basis is preserved" do
        tx = transaction("TFSA", "ZEQT.TO")

        # 2210.035 / 100 — NOT the 22.94 market price, which would erase the gain.
        assert_equal BigDecimal("22.10035"), tx.price
        assert_equal BigDecimal("100"), tx.shares
        assert_equal BigDecimal("2210.035"), tx.shares * tx.price
      end

      test "a book value with more decimals than the price column rounds to 6dp" do
        tx = transaction("TFSA", "XNDU.TO")

        # 5769.289834710743801652892562 / 213 = 27.0858677686...
        assert_equal BigDecimal("27.085868"), tx.price
        assert_equal 6, tx.price.scale, "price must fit numeric(16,6)"
      end

      test "synthesized trades are opening buys with no fees" do
        tx = transaction("RRSP", "AAPL")

        assert_equal "buy", tx.side
        assert_equal "normal", tx.kind
        assert_equal BigDecimal(0), tx.fees
        assert_nil tx.recurring_key
      end

      test "every trade is dated from the report's As of trailer" do
        dates = @document.portfolios.flat_map { |p| p.transactions.map(&:executed_on) }.uniq

        assert_equal [ Date.new(2026, 3, 4) ], dates
      end

      test "each transaction carries a provenance note naming the synthesis" do
        note = transaction("RRSP", "AAPL").notes

        assert_includes note, "holdings report"
        assert_includes note, "2026-03-04"
        assert_includes note, "not the real purchase date"
      end

      # --- Instrument identity ---

      test "non-US listings are venue-suffixed and US ones are not" do
        assert_equal %w[AAPL FINN.NE META.TO XNDU.TO ZEQT.TO],
                     @document.instruments.map(&:symbol).sort
      end

      test "instrument identity comes from the file, including currency and type" do
        specs = @document.instruments.index_by(&:symbol)

        assert_equal "CAD", specs["ZEQT.TO"].currency
        assert_equal "etf", specs["ZEQT.TO"].instrument_type
        assert_equal "BMO All-Equity ETF", specs["ZEQT.TO"].name

        assert_equal "CAD", specs["META.TO"].currency
        assert_equal "stock", specs["META.TO"].instrument_type

        assert_equal "USD", specs["AAPL"].currency
        assert_equal "stock", specs["AAPL"].instrument_type
      end

      # --- Rows that must be skipped, loudly ---

      test "a short position is skipped with a warning, not imported" do
        symbols = @document.portfolios.flat_map { |p| p.transactions.map(&:symbol) }

        assert_not_includes symbols, "BADSHORT.TO"
        assert @document.warnings.any? { |w| w.include?("BADSHORT") && w.include?("short") },
               "expected a warning naming the skipped short position, got: #{@document.warnings.inspect}"
      end

      test "a zero-quantity position is skipped with a warning" do
        symbols = @document.portfolios.flat_map { |p| p.transactions.map(&:symbol) }

        assert_not_includes symbols, "ZEROQTY.TO"
        assert @document.warnings.any? { |w| w.include?("ZEROQTY") && w.include?("quantity") },
               "expected a warning naming the skipped zero-quantity row"
      end

      test "skipping does not disturb the surviving rows" do
        assert_equal %w[FINN.NE META.TO XNDU.TO ZEQT.TO], portfolio("TFSA").transactions.map(&:symbol).sort
        assert_equal %w[AAPL], portfolio("RRSP").transactions.map(&:symbol)
      end

      # --- Warnings the user must see ---

      test "warns up front that the trade history is synthesized" do
        assert @document.warnings.any? { |w| w.include?("no trade history") && w.include?("2026-03-04") },
               "the synthesized-history caveat must be stated, got: #{@document.warnings.inspect}"
      end

      test "consolidates venue-suffixing into ONE warning listing every mapping" do
        notes = @document.warnings.select { |w| w.include?("venue-suffixed") }

        assert_equal 1, notes.size, "one consolidated note, not one per row"
        assert_includes notes.first, "META → META.TO"
        assert_includes notes.first, "FINN → FINN.NE"
        # The user must be told these holdings will value at zero — the provider
        # directory has no non-US coverage at all.
        assert_includes notes.first, "Price history is unavailable"
      end

      # --- Number parsing tolerance ---

      test "tolerates thousands separators, currency symbols and parenthesized negatives" do
        parser = HoldingsCsvParser.new("")

        assert_equal BigDecimal("1234.56"), parser.send(:decimal, "$1,234.56")
        assert_equal BigDecimal("-42"), parser.send(:decimal, "(42)")
        assert_nil parser.send(:decimal, "")
        assert_nil parser.send(:decimal, "n/a")
      end

      # --- Missing As of trailer ---

      test "falls back to today and says so when there is no As of trailer" do
        body = @body.lines.reject { |line| line.include?("As of") }.join
        document = HoldingsCsvParser.new(body, today: Date.new(2026, 6, 1)).call

        dates = document.portfolios.flat_map { |p| p.transactions.map(&:executed_on) }.uniq
        assert_equal [ Date.new(2026, 6, 1) ], dates
        assert document.warnings.any? { |w| w.include?("no \"As of\" date") },
               "a fabricated trade date must be disclosed"
      end

      # --- Unreadable input ---

      test "a file with no holdings rows is rejected as unreadable" do
        header = @body.lines.first

        error = assert_raises(UnreadableFile) { HoldingsCsvParser.call(header) }
        assert_includes error.message, "no holdings rows"
      end

      test "an account whose every row is skipped yields no empty portfolio" do
        body = [
          @body.lines.first,
          %("EMPTY","","","","NOPE","TSX","XTSE","x","EQUITY","0","LONG","1","CAD","0","CAD","0","CAD","0","CAD","0","CAD"\n)
        ].join

        document = HoldingsCsvParser.call(body)

        assert_empty document.portfolios, "an all-skipped account must not create an empty portfolio"
      end
    end
  end
end
