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

      def cash(name) = portfolio(name).cash_transactions.sort_by(&:occurred_on)
      def cash_of(name, kind) = cash(name).select { |c| c.kind == kind }
      def ingested_note = @document.warnings.find { |w| w.include?("cash ledger") }

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

      # --- Cash activity (issue #80) ---

      test "maps all five cash activities onto the six CashTransaction kinds" do
        assert_equal [ [ "deposit", BigDecimal("5000"), Date.new(2025, 4, 10) ] ],
                     cash_of("TFSA", "deposit").reject { |c| c.notes }.map { |c| [ c.kind, c.amount, c.occurred_on ] },
                     "MoneyMovement with a positive net is a deposit"
        assert_equal [ BigDecimal("73.7") ], cash_of("TFSA", "dividend_cash").map(&:amount)
        assert_equal [ BigDecimal("0.01") ], cash_of("TFSA", "interest").map(&:amount)
        assert_equal [ BigDecimal("-0.49") ], cash_of("TFSA", "tax").map(&:amount)
        assert_equal [ BigDecimal("172.5") ], cash_of("TFSA", "fee").map(&:amount)
        assert_equal [ BigDecimal("0.02") ], cash_of("RRSP", "interest").map(&:amount)
      end

      test "MoneyMovement's direction comes from the sign of net_cash_amount" do
        body = <<~CSV
          transaction_date,account_type,activity_type,activity_sub_type,description,symbol,name,currency,quantity,unit_price,commission,net_cash_amount
          2025-01-02,TFSA,MoneyMovement,EFT,Deposit,,,CAD,100,,,100
          2025-01-03,TFSA,MoneyMovement,EFT,Withdrawal,,,CAD,-40,,,-40
        CSV

        rows = ActivitiesCsvParser.call(body).portfolios.sole.cash_transactions

        assert_equal [ [ "deposit", BigDecimal("100") ], [ "withdrawal", BigDecimal("-40") ] ],
                     rows.map { |c| [ c.kind, c.amount ] }
      end

      test "a NEGATIVE dividend and a POSITIVE tax survive with their signs" do
        # A dividend reversal and a tax refund are real broker rows. `.abs`
        # anywhere in this pipeline turns a clawback into income and a refund into
        # a charge — silently, because both are legal values for their kind.
        body = <<~CSV
          transaction_date,account_type,activity_type,activity_sub_type,description,symbol,name,currency,quantity,unit_price,commission,net_cash_amount
          2025-01-03,TFSA,Dividend,-,Dividend reversal,ZZZ,Zed Inc,CAD,-5.25,,,-5.25
          2025-01-04,TFSA,Tax,NRT,Withholding tax refund,,,CAD,3.1,,,3.1
        CSV

        rows = ActivitiesCsvParser.call(body).portfolios.sole.cash_transactions

        assert_equal [ [ "dividend_cash", BigDecimal("-5.25") ], [ "tax", BigDecimal("3.1") ] ],
                     rows.map { |c| [ c.kind, c.amount ] }
      end

      test "cash uses transaction_date, never settlement_date" do
        body = <<~CSV
          transaction_date,settlement_date,account_type,activity_type,activity_sub_type,description,symbol,name,currency,quantity,unit_price,commission,net_cash_amount
          2025-01-02,2025-01-06,TFSA,MoneyMovement,EFT,Deposit,,,CAD,100,,,100
        CSV

        assert_equal Date.new(2025, 1, 2),
                     ActivitiesCsvParser.call(body).portfolios.sole.cash_transactions.sole.occurred_on
      end

      test "the amount is rounded to the cent, not to the column's full precision" do
        body = <<~CSV
          transaction_date,account_type,activity_type,activity_sub_type,description,symbol,name,currency,quantity,unit_price,commission,net_cash_amount
          2025-01-03,TFSA,Interest,-,Stock lending,,,CAD,0.014999,,,0.014999
        CSV

        # amount is numeric(12,2); PostgreSQL would round it anyway, and a figure
        # that disagrees with the stored one is how a preview lies about a total.
        assert_equal BigDecimal("0.01"),
                     ActivitiesCsvParser.call(body).portfolios.sole.cash_transactions.sole.amount
      end

      test "a cash row with no amount is DROPPED with a warning, not imported at zero" do
        # The cash_transactions_amount_sign CHECK forbids a zero amount, so a zero
        # row would abort the whole portfolio's savepoint on import. One warned
        # no-op row beats one failed portfolio.
        body = <<~CSV
          transaction_date,account_type,activity_type,activity_sub_type,description,symbol,name,currency,quantity,unit_price,commission,net_cash_amount
          2025-01-02,TFSA,MoneyMovement,EFT,Deposit,,,CAD,100,,,100
          2025-01-03,TFSA,Dividend,-,A dividend of nothing,ZZZ,Zed Inc,CAD,0,,,0
          2025-01-04,TFSA,Interest,-,Interest with a blank amount,,,CAD,,,,
        CSV

        document = ActivitiesCsvParser.call(body)

        assert_equal [ "deposit" ], document.portfolios.sole.cash_transactions.map(&:kind)
        note = document.warnings.find { |w| w.include?("no amount") }
        assert_not_nil note, "a dropped row must be reported, got: #{document.warnings.inspect}"
        assert_includes note, "1 dividend payment"
        assert_includes note, "1 interest payment"
        assert_includes note, "dropped"
      end

      test "a sub-half-cent amount that rounds to zero is dropped rather than failing the CHECK" do
        body = <<~CSV
          transaction_date,account_type,activity_type,activity_sub_type,description,symbol,name,currency,quantity,unit_price,commission,net_cash_amount
          2025-01-02,TFSA,MoneyMovement,EFT,Deposit,,,CAD,100,,,100
          2025-01-03,TFSA,Interest,-,A rounding residue,,,CAD,0.004,,,0.004
        CSV

        document = ActivitiesCsvParser.call(body)

        assert_equal [ "deposit" ], document.portfolios.sole.cash_transactions.map(&:kind)
        assert document.warnings.any? { |w| w.include?("no amount") }
      end

      test "a trade produces NO cash row — the ledger derives a trade's cash from the trade" do
        # Emitting one here would debit every purchase twice.
        body = <<~CSV
          transaction_date,account_type,activity_type,activity_sub_type,description,symbol,name,currency,quantity,unit_price,commission,net_cash_amount
          2025-01-02,TFSA,Trade,BUY,Bought 1 share,ZZZ,Zed Inc,CAD,1,10,0,-10
          2025-01-03,TFSA,Trade,SELL,Sold 1 share,ZZZ,Zed Inc,CAD,-1,12,0,12
        CSV

        assert_empty ActivitiesCsvParser.call(body).portfolios.sole.cash_transactions
      end

      test "a SUBDIVISION produces no cash row — a split moves shares, not money" do
        assert_empty cash("TFSA").select { |c| c.occurred_on == Date.new(2025, 8, 18) }
      end

      # --- The SecurityTransfer offset: issue #80 test 10 ---

      test "a SecurityTransfer nets to EXACTLY zero cash" do
        # The synthesized buy/sell would otherwise debit/credit cash that never
        # crossed the account boundary — worth about -$51,000 in the owner's real
        # file. Portfolios::CashLedger computes
        #   balance = Σ cash.amount − Σ TradeCash.for(tx)
        # so netting to zero is exactly this identity, and it holds per direction:
        # a deposit for the buy, a withdrawal for the sell.
        transfers = transactions("TFSA", "XSB.TO")
        offsets = cash("TFSA").select { |c| c.notes&.include?("broker transfer") }

        assert_equal 2, transfers.size
        assert_equal 2, offsets.size

        trade_cash = transfers.sum(BigDecimal(0)) { |tx| Portfolios::TradeCash.for(tx) }
        offset_cash = offsets.sum(BigDecimal(0), &:amount)

        assert_equal BigDecimal(0), offset_cash - trade_cash,
                     "a transfer must move shares without moving cash"
      end

      test "a transfer IN offsets with a deposit, a transfer OUT with a withdrawal" do
        offsets = cash("TFSA").select { |c| c.notes&.include?("broker transfer") }
                              .index_by(&:kind)

        deposit = offsets.fetch("deposit")
        assert_equal BigDecimal("9706.62"), deposit.amount
        assert_equal Date.new(2026, 5, 5), deposit.occurred_on,
                     "the offset must share its trade's date or the benchmark's synthetic fill moves"
        assert_includes deposit.notes, "no cash crossed the account boundary"

        withdrawal = offsets.fetch("withdrawal")
        assert_equal BigDecimal("-267.4"), withdrawal.amount
        assert_equal Date.new(2026, 5, 6), withdrawal.occurred_on
      end

      test "the transfer offset is reconstructed from the trade, so it cannot drift by a cent" do
        # net_cash_amount / quantity is rounded to 6 dp, so shares x price can
        # differ from the raw ledger amount by a fraction of a cent. The offset
        # must match what TradeCash charges, not what the file said.
        body = <<~CSV
          transaction_date,account_type,activity_type,activity_sub_type,description,symbol,name,currency,quantity,unit_price,commission,net_cash_amount
          2026-05-05,TFSA,SecurityTransfer,-,Transfer of 7.0 shares into the account,ZZZ,Zed Inc,CAD,7,,,100
        CSV

        spec = ActivitiesCsvParser.call(body).portfolios.sole
        tx = spec.transactions.sole
        offset = spec.cash_transactions.sole

        # 100 / 7 = 14.285714285... -> 14.285714; 7 x 14.285714 = 99.999998 -> 100.00
        assert_equal Portfolios::TradeCash.for(tx), offset.amount
      end

      test "cash-only rows create no transactions" do
        all = @document.portfolios.flat_map(&:transactions)

        # TFSA: 6 trades + 2 security transfers. RRSP: 3 trades. Everything else in
        # the fixture is a deposit, dividend, interest, tax, administrative credit
        # or the corporate action (which becomes a split, not a transaction).
        assert_equal 8, portfolio("TFSA").transactions.size
        assert_equal 3, portfolio("RRSP").transactions.size
        assert_equal 11, all.size
      end

      test "reports every ingested cash category with a count and a total" do
        note = ingested_note

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

        note = ActivitiesCsvParser.call(body).warnings.find { |w| w.include?("cash ledger") }

        assert_includes note, "2 dividend payments totalling 4.00"
        assert_includes note, "1 cash movement totalling 100.00"
        assert_no_match(/1 dividend payments|2 dividend payment /, note)
      end

      test "amounts are formatted to two decimals with thousands separators" do
        # "5000.0" is a raw BigDecimal leaking into user-facing prose.
        assert_no_match(/totalling \d+\.\d(?!\d)/, ingested_note)
      end

      test "the report states what the cash ledger does with the rows, not that they were lost" do
        # This test used to assert the OPPOSITE: that contributed capital is
        # "derived from what you actually bought" and that a dividend-funded buy
        # "understates return". Both were true only while there was nowhere to put
        # a dividend. Shipping either now sends the user editing transaction kinds
        # to fix a problem that no longer exists.
        note = ingested_note

        assert_not_nil note
        assert_includes note, "total value includes its cash balance"
        assert_includes note, "contributed capital comes from the deposit rows"
        assert_includes note, "not counted as a new contribution"

        joined = @document.warnings.join(" ")
        assert_no_match(/not a cash balance/, joined)
        assert_no_match(/understates return/, joined)
        assert_no_match(/dividend reinvestment/, joined)
      end

      test "no warning claims a completed write, because previews reuse these strings" do
        # The same strings serve dry_run, where nothing has been written yet.
        assert_not_empty @document.warnings
        @document.warnings.each do |warning|
          assert_no_match(/\b(was|were)\s+imported\b/i, warning,
                          "a preview must not claim the write already happened: #{warning.inspect}")
        end
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

      test "an account whose every row is cash is KEPT, because its money is real" do
        # This asserted `assert_empty document.portfolios` before there was a cash
        # ledger, when a portfolio could only be made of transactions. Dropping the
        # account now would silently discard a $100 deposit — the exact failure
        # this feature exists to end.
        body = <<~CSV
          transaction_date,account_type,activity_type,activity_sub_type,description,symbol,name,currency,quantity,unit_price,commission,net_cash_amount
          2025-01-02,TFSA,MoneyMovement,EFT,Deposit,,,CAD,100,,,100
        CSV

        spec = ActivitiesCsvParser.call(body).portfolios.sole

        assert_empty spec.transactions
        assert_equal "deposit", spec.cash_transactions.sole.kind
        assert_equal BigDecimal("100"), spec.cash_transactions.sole.amount
      end

      test "an account with neither trades nor cash still yields no empty portfolio" do
        body = <<~CSV
          transaction_date,account_type,activity_type,activity_sub_type,description,symbol,name,currency,quantity,unit_price,commission,net_cash_amount
          2025-01-02,TFSA,Teleportation,WARP,Something new,,,CAD,1,,,5
        CSV

        assert_empty ActivitiesCsvParser.call(body).portfolios
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
