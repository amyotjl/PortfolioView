require "test_helper"

# backlog #068: broker ACTIVITY LEDGER csv -> Document.
#
# The fixture (test/fixtures/files/activities_report.csv) mirrors the real
# Wealthsimple activities export and packs in every case that needed a decision:
# a US listing settled through FX, CAD-listed securities with no exchange column,
# a CAD-hedged CDR whose ticker collides with a US one, an already-suffixed
# symbol, a share-class dot, a SELL with its negative quantity, security transfers
# in and out, a SUBDIVISION that is really a split, and one row of every
# cash-only activity type.
module Portfolios
  module Transfer
    class ActivitiesCsvParserTest < ActiveSupport::TestCase
      setup do
        @body = file_fixture("activities_report.csv").read
        @document = ActivitiesCsvParser.call(@body)
      end

      def portfolio(name) = @document.portfolios.find { |p| p.name == name }
      def transactions(name, symbol)
        portfolio(name).transactions.select { |t| t.symbol == symbol }.sort_by(&:executed_on)
      end

      # --- Shape ---

      test "groups rows into one portfolio per account type" do
        assert_equal %w[RRSP TFSA], @document.portfolios.map(&:name).sort
        assert_equal ACTIVITIES_CSV_FORMAT, @document.format
      end

      test "detector routes this file to this parser, not the holdings parser" do
        assert_equal ActivitiesCsvParser, Detector.new(@body).parser
      end

      test "the detector still routes a holdings snapshot to the holdings parser" do
        # The two CSV branches must not shadow one another.
        holdings = file_fixture("holdings_report.csv").read
        assert_equal HoldingsCsvParser, Detector.new(holdings).parser
      end

      # --- Trades ---

      test "a BUY keeps its quantity, price and commission" do
        tx = transactions("TFSA", "ZEQT.TO").first

        assert_equal "buy", tx.side
        assert_equal "normal", tx.kind
        assert_equal BigDecimal("91.0199"), tx.shares
        assert_equal BigDecimal("66"), tx.price
        assert_equal BigDecimal("1.25"), tx.fees
        assert_equal Date.new(2025, 4, 12), tx.executed_on
      end

      test "a SELL's NEGATIVE quantity becomes positive shares on a sell" do
        # shares has a `> 0` CHECK constraint, so importing -4 would be a 500.
        tx = transactions("TFSA", "QQQ").find { |t| t.side == "sell" }

        assert_equal BigDecimal("4"), tx.shares
        assert_operator tx.shares, :>, 0
      end

      test "uses transaction_date, never settlement_date" do
        # Settlement can trail the trade by days and would shift every trade off
        # the day it actually happened.
        dates = @document.portfolios.flat_map { |p| p.transactions.map(&:executed_on) }
        assert_includes dates, Date.new(2025, 4, 12)
      end

      test "a 10-decimal unit price is rounded to the price column's scale" do
        tx = transactions("TFSA", "QQQ").first

        # 655.150217494 -> numeric(16,6)
        assert_equal BigDecimal("655.150217"), tx.price
        assert_operator tx.price.scale, :<=, 6
      end

      test "every imported transaction satisfies the column constraints" do
        all = @document.portfolios.flat_map(&:transactions)

        assert_not_empty all
        all.each do |tx|
          assert_operator tx.shares, :>, 0, "shares > 0 CHECK"
          assert_operator tx.price, :>, 0, "price > 0 CHECK"
          assert_operator tx.fees, :>=, 0, "fees >= 0 CHECK"
          assert_operator tx.shares.scale, :<=, 8
          assert_operator tx.price.scale, :<=, 6
          assert_not_nil tx.executed_on
        end
      end

      # --- Venue inference: the FX-Rate signal ---

      test "a trade settled through an FX conversion is a US listing and keeps its bare ticker" do
        assert_equal %w[QQQ], transactions("TFSA", "QQQ").map(&:symbol).uniq
        spec = @document.instruments.find { |i| i.symbol == "QQQ" }
        assert_equal "USD", spec.currency,
                     "the currency column is the ACCOUNT's currency and must not be read as the instrument's"
      end

      test "a CAD-listed security is venue-suffixed even though the file names no exchange" do
        assert_equal "CAD", @document.instruments.find { |i| i.symbol == "ZEQT.TO" }.currency
        assert_not @document.instruments.map(&:symbol).include?("ZEQT")
      end

      test "the CAD-hedged CDR does not take the US ticker" do
        # META here is "Meta CDR (CAD Hedged)" on a Canadian venue — a different
        # security from NASDAQ's META, and `instruments` is unique on symbol alone.
        assert_equal 1, transactions("TFSA", "META.TO").size
        assert_empty transactions("TFSA", "META")
      end

      test "the FX verdict is reached per SYMBOL over the whole file, not per row" do
        # Only trades carry the FX marker; a dividend or transfer for the same
        # symbol does not, so a per-row test would classify the same security two
        # different ways. QQQ's buy and sell must agree.
        assert_equal %w[QQQ QQQ], transactions("TFSA", "QQQ").map(&:symbol)
      end

      test "an FX marker on a non-trade row does not make that symbol foreign" do
        # The fixture's RRSP interest row carries an FX Rate but no symbol.
        assert_equal "CAD", @document.instruments.find { |i| i.symbol == "ZEQT.TO" }.currency
      end

      test "an already-suffixed symbol is not suffixed twice" do
        assert_equal 2, transactions("RRSP", "XNDU.TO").size
        assert_not @document.instruments.map(&:symbol).include?("XNDU.TO.TO")
      end

      test "a share-class dot is not mistaken for a venue suffix" do
        # HPS.A is Hammond Power Solutions class A, not a venue — so it still
        # needs a venue suffix to be collision-proof, giving HPS.A.TO.
        assert_equal 1, transactions("TFSA", "HPS.A.TO").size
      end

      # --- Instrument identity ---

      test "infers etf vs stock from the security name" do
        specs = @document.instruments.index_by(&:symbol)

        assert_equal "etf", specs["ZEQT.TO"].instrument_type
        assert_equal "etf", specs["QQQ"].instrument_type
        assert_equal "etf", specs["XSB.TO"].instrument_type
        assert_equal "stock", specs["META.TO"].instrument_type
        assert_equal "stock", specs["HPS.A.TO"].instrument_type
      end

      test "carries the security name through" do
        assert_equal "BMO All-Equity ETF", @document.instruments.find { |i| i.symbol == "ZEQT.TO" }.name
      end

      # --- Security transfers ---

      test "a transfer IN becomes a buy priced at its per-share value" do
        tx = transactions("TFSA", "XSB.TO").find { |t| t.side == "buy" }

        assert_equal BigDecimal("363"), tx.shares
        # 9706.62 / 363
        assert_equal BigDecimal("26.74"), tx.price
        assert_includes tx.notes, "transfer into"
        assert_includes tx.notes, "no unit price"
      end

      test "a transfer OUT becomes a sell priced at its per-share value" do
        tx = transactions("TFSA", "XSB.TO").find { |t| t.side == "sell" }

        assert_equal BigDecimal("10"), tx.shares
        assert_equal BigDecimal("26.74"), tx.price
        assert_includes tx.notes, "transfer out of"
      end

      test "transfers preserve the value they arrived with" do
        tx = transactions("TFSA", "XSB.TO").find { |t| t.side == "buy" }

        assert_equal BigDecimal("9706.62"), (tx.shares * tx.price)
      end

      # --- The SUBDIVISION -> split conversion ---

      test "a SUBDIVISION share delta is converted to a split RATIO" do
        split = @document.splits.sole

        assert_equal "ZEQT.TO", split.symbol
        assert_equal Date.new(2025, 8, 18), split.ex_date
        # position before was 91.0199; (91.0199 + 182.0398) / 91.0199 == 3
        assert_equal BigDecimal("3"), split.ratio
      end

      test "the subdivision does NOT become a transaction" do
        # A share adjustment has no price, and any invented price would inject
        # phantom cash into contributed capital.
        zeqt = transactions("TFSA", "ZEQT.TO")

        assert_equal 2, zeqt.size, "only the two real buys"
        assert_not zeqt.any? { |t| t.shares == BigDecimal("182.0398") }
      end

      test "reports the derived split, its ratio and its global reach" do
        note = @document.warnings.find { |w| w.include?("SUBDIVISION") }

        assert_not_nil note, "a derived ratio is an inference and must be disclosed"
        assert_includes note, "3.0:1 split"
        assert_includes note, "91.0199"
        assert_includes note, "every portfolio holding ZEQT.TO"
      end

      test "a subdivision with no prior position is skipped and says what it costs" do
        body = <<~CSV
          transaction_date,account_type,activity_type,activity_sub_type,description,symbol,name,currency,quantity,unit_price,commission,net_cash_amount
          2025-08-18,TFSA,CorporateAction,SUBDIVISION,Corrected quantity of shares by 5.0,ZZZ,Zed Inc,CAD,5,,,
          2025-09-01,TFSA,Trade,BUY,Bought 1 share,ZZZ,Zed Inc,CAD,1,10,0,-10
        CSV

        document = ActivitiesCsvParser.call(body)

        assert_empty document.splits
        note = document.warnings.find { |w| w.include?("no position before that date") }
        assert_not_nil note
        assert_includes note, "short by 5.0"
      end

      test "one split per (symbol, ex_date) even when several accounts report it" do
        body = <<~CSV
          transaction_date,account_type,activity_type,activity_sub_type,description,symbol,name,currency,quantity,unit_price,commission,net_cash_amount
          2025-01-02,TFSA,Trade,BUY,Bought 10 shares,ZZZ,Zed Fund,CAD,10,30,0,-300
          2025-01-02,RRSP,Trade,BUY,Bought 20 shares,ZZZ,Zed Fund,CAD,20,30,0,-600
          2025-06-01,TFSA,CorporateAction,SUBDIVISION,Corrected quantity of shares by 20.0,ZZZ,Zed Fund,CAD,20,,,
          2025-06-01,RRSP,CorporateAction,SUBDIVISION,Corrected quantity of shares by 40.0,ZZZ,Zed Fund,CAD,40,,,
        CSV

        document = ActivitiesCsvParser.call(body)

        assert_equal 1, document.splits.size, "a split is instrument-global, not per account"
        assert_equal BigDecimal("3"), document.splits.sole.ratio
      end

      test "contradictory ratios across accounts record nothing rather than guessing" do
        body = <<~CSV
          transaction_date,account_type,activity_type,activity_sub_type,description,symbol,name,currency,quantity,unit_price,commission,net_cash_amount
          2025-01-02,TFSA,Trade,BUY,Bought 10 shares,ZZZ,Zed Fund,CAD,10,30,0,-300
          2025-01-02,RRSP,Trade,BUY,Bought 20 shares,ZZZ,Zed Fund,CAD,20,30,0,-600
          2025-06-01,TFSA,CorporateAction,SUBDIVISION,Corrected quantity of shares by 20.0,ZZZ,Zed Fund,CAD,20,,,
          2025-06-01,RRSP,CorporateAction,SUBDIVISION,Corrected quantity of shares by 100.0,ZZZ,Zed Fund,CAD,100,,,
        CSV

        document = ActivitiesCsvParser.call(body)

        assert_empty document.splits
        assert document.warnings.any? { |w| w.include?("different split ratios") }
      end

      # --- Cash-only activity ---

      test "cash-only rows create no transactions" do
        all = @document.portfolios.flat_map(&:transactions)

        # TFSA: 6 trades + 2 security transfers. RRSP: 3 trades. Everything else in
        # the fixture is a deposit, dividend, interest, tax, administrative credit
        # or the corporate action (which becomes a split, not a transaction).
        assert_equal 8, portfolio("TFSA").transactions.size
        assert_equal 3, portfolio("RRSP").transactions.size
        assert_equal 11, all.size
      end

      test "reports every skipped cash category with a count and a total" do
        note = @document.warnings.find { |w| w.include?("not a cash balance") }

        assert_not_nil note
        assert_includes note, "1 dividend payment totalling 73.70"
        assert_includes note, "1 cash movement totalling 5,000.00"
        assert_includes note, "1 tax withholding"
        assert_includes note, "1 administrative credit"
      end

      test "category labels agree in number with their count" do
        # "1 dividend payments" and "62 dividend payment" both read as a bug.
        body = <<~CSV
          transaction_date,account_type,activity_type,activity_sub_type,description,symbol,name,currency,quantity,unit_price,commission,net_cash_amount
          2025-01-02,TFSA,Trade,BUY,Bought 1 share,ZZZ,Zed Inc,CAD,1,10,0,-10
          2025-01-03,TFSA,Dividend,-,Cash dividend,ZZZ,Zed Inc,CAD,1.5,,,1.5
          2025-01-04,TFSA,Dividend,-,Cash dividend,ZZZ,Zed Inc,CAD,2.5,,,2.5
          2025-01-05,TFSA,MoneyMovement,EFT,Deposit,,,CAD,100,,,100
        CSV

        note = ActivitiesCsvParser.call(body).warnings.find { |w| w.include?("not a cash balance") }

        assert_includes note, "2 dividend payments totalling 4.00"
        assert_includes note, "1 cash movement totalling 100.00"
        assert_no_match(/1 dividend payments|2 dividend payment /, note)
      end

      test "amounts are formatted to two decimals with thousands separators" do
        note = @document.warnings.find { |w| w.include?("not a cash balance") }

        # "5000.0" is a raw BigDecimal leaking into user-facing prose.
        assert_no_match(/totalling \d+\.\d(?!\d)/, note)
      end

      test "states both consequences of having no cash ledger" do
        note = @document.warnings.find { |w| w.include?("Two consequences") }

        assert_not_nil note
        assert_includes note, "derived from what you actually bought"
        assert_includes note, "understates return"
      end

      test "an unrecognized activity type is skipped by name rather than silently" do
        body = <<~CSV
          transaction_date,account_type,activity_type,activity_sub_type,description,symbol,name,currency,quantity,unit_price,commission,net_cash_amount
          2025-01-02,TFSA,Trade,BUY,Bought 1 share,ZZZ,Zed Inc,CAD,1,10,0,-10
          2025-02-02,TFSA,Teleportation,WARP,Something new,ZZZ,Zed Inc,CAD,1,,,5
        CSV

        document = ActivitiesCsvParser.call(body)

        assert_equal 1, document.portfolios.sole.transactions.size
        assert document.warnings.any? { |w| w.include?("1 Teleportation row") },
               "a format change must surface, got: #{document.warnings.inspect}"
      end

      # --- Warning volume ---

      test "caps the venue-suffix example list so it stays readable" do
        # The real file renames 39 tickers; a 39-item paragraph buries the two
        # sentences that matter.
        note = @document.warnings.find { |w| w.include?("venue-suffixed") }

        assert_not_nil note
        assert_operator note.scan("→").size, :<=, ActivitiesCsvParser::EXAMPLE_LIMIT
      end

      # --- Unreadable input ---

      test "a header with no data rows is rejected" do
        error = assert_raises(UnreadableFile) { ActivitiesCsvParser.call(@body.lines.first) }

        assert_includes error.message, "no activity rows"
      end

      test "an account whose every row is cash yields no empty portfolio" do
        body = <<~CSV
          transaction_date,account_type,activity_type,activity_sub_type,description,symbol,name,currency,quantity,unit_price,commission,net_cash_amount
          2025-01-02,TFSA,MoneyMovement,EFT,Deposit,,,CAD,100,,,100
        CSV

        document = ActivitiesCsvParser.call(body)

        assert_empty document.portfolios
      end

      test "a trade missing its price or quantity is dropped, not imported at zero" do
        body = <<~CSV
          transaction_date,account_type,activity_type,activity_sub_type,description,symbol,name,currency,quantity,unit_price,commission,net_cash_amount
          2025-01-02,TFSA,Trade,BUY,Bought some shares,ZZZ,Zed Inc,CAD,,10,0,-10
          2025-01-03,TFSA,Trade,BUY,Bought some shares,ZZZ,Zed Inc,CAD,5,,0,-10
          2025-01-04,TFSA,Trade,BUY,Bought 1 share,ZZZ,Zed Inc,CAD,1,10,0,-10
        CSV

        document = ActivitiesCsvParser.call(body)

        assert_equal 1, document.portfolios.sole.transactions.size
      end
      # --- #79: a guessed venue must be reported as a guess --------------------

      # NOTE ON THE BASELINE: `listed_instruments` is EMPTY in the test
      # environment, so every venue-less symbol in the fixture falls back to .TO
      # exactly as it did before #79. That is why the rest of this file is
      # unchanged — and it is also why the guess warning is what needs asserting
      # here, since the fallback is the path these tests take.
      test "the report says which venues are a GUESS, and names them" do
        note = @document.warnings.find { |w| w.include?("is a GUESS") || w.include?("are a GUESS") }

        assert note, "a guessed venue must be reported, got: #{@document.warnings.inspect}"
        assert_includes note, "ZEQT.TO"
        assert_includes note, ".TO) is assumed"
        assert_match(/cost basis stays exact/, note,
                     "say what is and is not affected, or the warning reads as data loss")
      end

      test "the guess warning is TENSE-NEUTRAL, because dry_run shows it too" do
        # #64 shipped a preview reading "was imported" and told users their data
        # had already been written. Locked for this warning too.
        note = @document.warnings.find { |w| w.include?("GUESS") }

        assert_no_match(/was imported|were imported/, note)
      end

      test "a symbol the directory settles to ONE venue is not reported as a guess" do
        # The FINN case, driven end to end through the parser: with a directory row
        # naming the venue, the symbol resolves to it and drops out of the guess
        # list entirely.
        ListedInstrument.create!(symbol: "ZEQT.NE", exchange: "NEO", asset_type: "ETF",
                                 currency: "CAD")

        document = ActivitiesCsvParser.call(@body)
        symbols = document.portfolios.flat_map { |p| p.transactions.map(&:symbol) }.uniq

        assert_includes symbols, "ZEQT.NE", "the directory venue must win over the .TO default"
        assert_not_includes symbols, "ZEQT.TO"

        guess = document.warnings.find { |w| w.include?("GUESS") }
        assert_not_includes guess.to_s, "ZEQT",
                            "a resolved venue is not a guess and must not be reported as one"
      end

      test "an AMBIGUOUS base symbol stays a guess even though the directory knows it" do
        # Two Canadian venues for one base symbol. Picking one would bind the
        # holding to the wrong security some of the time, so it falls back to .TO
        # AND is reported — the directory knowing something is not the same as the
        # directory settling it.
        ListedInstrument.create!(symbol: "ZEQT.NE", exchange: "NEO", asset_type: "ETF",
                                 currency: "CAD")
        ListedInstrument.create!(symbol: "ZEQT.TO", exchange: "TSX", asset_type: "ETF",
                                 currency: "CAD")

        document = ActivitiesCsvParser.call(@body)
        symbols = document.portfolios.flat_map { |p| p.transactions.map(&:symbol) }.uniq

        assert_includes symbols, "ZEQT.TO"
        assert_includes document.warnings.find { |w| w.include?("GUESS") }.to_s, "ZEQT.TO"
      end
    end
  end
end
