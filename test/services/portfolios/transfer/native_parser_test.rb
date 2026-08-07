require "test_helper"

# backlog #064: the native envelope is a TRUST BOUNDARY — it arrives over an
# upload form and may be hand-edited, truncated, or hostile. Nothing here may
# raise anything but UnreadableFile (which the controller renders as a 422 on the
# `file` field); a bare TypeError/NoMethodError would surface as a 500.
module Portfolios
  module Transfer
    class NativeParserTest < ActiveSupport::TestCase
      def envelope(overrides = {})
        {
          "format" => NATIVE_FORMAT,
          "version" => NATIVE_VERSION_BASE,
          "instruments" => [
            { "symbol" => "AAPL", "name" => "Apple Inc", "instrument_type" => "stock", "currency" => "USD" }
          ],
          "portfolios" => [
            {
              "name" => "Retirement",
              "benchmark" => "S&P 500 (SPY)",
              "transactions" => [
                { "symbol" => "AAPL", "side" => "buy", "kind" => "normal", "shares" => "10.5",
                  "price" => "150.25", "fees" => "4.95", "executed_on" => "2024-01-05", "notes" => "hi" }
              ],
              "recurring_transactions" => []
            }
          ]
        }.deep_merge(overrides)
      end

      def parse(hash) = NativeParser.call(JSON.generate(hash))

      # --- Happy path coercion ---

      test "coerces decimals to BigDecimal and dates to Date" do
        transaction = parse(envelope).portfolios.first.transactions.first

        assert_equal BigDecimal("10.5"), transaction.shares
        assert_equal BigDecimal("150.25"), transaction.price
        assert_equal BigDecimal("4.95"), transaction.fees
        assert_equal Date.new(2024, 1, 5), transaction.executed_on
        assert_instance_of BigDecimal, transaction.shares
      end

      test "carries instrument identity through, defaulting currency to USD" do
        spec = parse(envelope("instruments" => [ { "symbol" => "zeqt.to", "currency" => nil } ])).instruments.first

        assert_equal "ZEQT.TO", spec.symbol, "symbols are normalized to upper case"
        assert_equal "USD", spec.currency
        assert_equal "stock", spec.instrument_type
      end

      test "a non-US instrument's currency and type survive verbatim" do
        spec = parse(envelope("instruments" => [
          { "symbol" => "ZEQT.TO", "name" => "BMO All-Equity ETF", "instrument_type" => "etf", "currency" => "CAD" }
        ])).instruments.first

        assert_equal "CAD", spec.currency
        assert_equal "etf", spec.instrument_type
      end

      test "an out-of-domain instrument_type is normalized instead of reaching the CHECK constraint" do
        spec = parse(envelope("instruments" => [ { "symbol" => "X", "instrument_type" => "crypto" } ])).instruments.first

        assert_equal "stock", spec.instrument_type
      end

      test "recurring rules default their key positionally and default active to true" do
        document = parse(envelope("portfolios" => [ envelope["portfolios"].first.merge(
          "recurring_transactions" => [
            { "symbol" => "AAPL", "amount_type" => "dollars", "dollar_amount" => "100",
              "frequency" => "monthly", "anchor_on" => "2024-01-31", "next_run_on" => "2024-02-29" }
          ]
        ) ]))

        rule = document.portfolios.first.recurring_transactions.first
        assert_equal "r1", rule.key
        assert_equal "buy", rule.side
        assert rule.active
        assert_equal BigDecimal("100"), rule.dollar_amount
        assert_nil rule.share_amount
      end

      # --- Cash (issue #80) ---

      def with_cash(rows, version: NATIVE_VERSION_CASH)
        parse(envelope("version" => version,
                       "portfolios" => [ envelope["portfolios"].first.merge("cash_transactions" => rows) ]))
      end

      test "reads a version-2 cash section, coercing amounts and dates" do
        document = with_cash([
          { "kind" => "deposit", "amount" => "1000.50", "occurred_on" => "2024-01-15", "notes" => "payday" }
        ])

        row = document.portfolios.first.cash_transactions.sole
        assert_equal "deposit", row.kind
        assert_equal BigDecimal("1000.50"), row.amount
        assert_instance_of BigDecimal, row.amount
        assert_equal Date.new(2024, 1, 15), row.occurred_on
        assert_equal "payday", row.notes
      end

      test "a negative amount is read verbatim and NEVER coerced toward its kind" do
        # A dividend reversal and a tax refund are legal rows whose sign IS the
        # information. A parser that "corrected" either would turn a clawback into
        # income, silently.
        rows = with_cash([
          { "kind" => "withdrawal", "amount" => "-250", "occurred_on" => "2024-02-01" },
          { "kind" => "dividend_cash", "amount" => "-5.25", "occurred_on" => "2024-02-02" },
          { "kind" => "tax", "amount" => "3.10", "occurred_on" => "2024-02-03" }
        ]).portfolios.first.cash_transactions

        assert_equal [ BigDecimal("-250"), BigDecimal("-5.25"), BigDecimal("3.1") ], rows.map(&:amount)
      end

      test "an absent cash section parses as empty, which is what keeps a v1 file working" do
        # No special back-compat code: absent -> [] -> not cash-tracked -> exactly
        # the pre-#80 behaviour. That is the payoff of "has >= 1 cash row" as the
        # predicate instead of a flag column.
        assert_empty parse(envelope).portfolios.first.cash_transactions
      end

      test "a version-2 envelope with no cash section is still readable" do
        assert_empty parse(envelope("version" => NATIVE_VERSION_CASH)).portfolios.first.cash_transactions
      end

      test "a cash section that is not an array, or holds non-hashes, does not crash" do
        assert_empty with_cash("nope").portfolios.first.cash_transactions
        assert_empty with_cash([ "nope", 42, nil ]).portfolios.first.cash_transactions
      end

      test "a garbage cash amount or date becomes nil so the MODEL reports it" do
        # Same rule as transactions: the user gets the message the cash form gives,
        # not a parser error, and never a silently zeroed row.
        row = with_cash([
          { "kind" => "deposit", "amount" => "ten dollars", "occurred_on" => "not-a-date" }
        ]).portfolios.first.cash_transactions.sole

        assert_nil row.amount
        assert_nil row.occurred_on
      end

      test "an unknown cash kind is carried through for the model's inclusion validation" do
        # Normalizing it to "deposit" would invent money movements the file never
        # described; the model rejects it with a message on the `kind` field.
        row = with_cash([
          { "kind" => "bonus", "amount" => "5", "occurred_on" => "2024-01-15" }
        ]).portfolios.first.cash_transactions.sole

        assert_equal "bonus", row.kind
        assert_not CashTransaction.new(kind: row.kind, amount: row.amount, occurred_on: row.occurred_on).valid?
      end

      # --- Rejections ---

      test "rejects invalid JSON with a position, not the parser's raw message" do
        error = assert_raises(UnreadableFile) { NativeParser.call('{"format": ') }

        assert_includes error.message, "not valid JSON"
      end

      test "rejects a JSON array or scalar at the top level" do
        assert_raises(UnreadableFile) { NativeParser.call("[]") }
        assert_raises(UnreadableFile) { NativeParser.call('"hello"') }
      end

      test "rejects a file whose format string is not ours" do
        error = assert_raises(UnreadableFile) { parse(envelope("format" => "someone.else")) }

        assert_includes error.message, "not a PortfolioView export"
      end

      test "rejects an unsupported version rather than guessing at the shape" do
        error = assert_raises(UnreadableFile) { parse(envelope("version" => 99)) }

        assert_includes error.message, "unsupported version"
      end

      test "rejects a missing portfolios array" do
        assert_raises(UnreadableFile) { NativeParser.call(JSON.generate(envelope.except("portfolios"))) }
      end

      test "rejects a portfolio with a blank name" do
        error = assert_raises(UnreadableFile) { parse(envelope("portfolios" => [ { "name" => "  " } ])) }

        assert_includes error.message, "no name"
      end

      # --- Hostile / malformed input must not 500 ---

      test "garbage decimals become nil so the model reports them, not the parser" do
        document = parse(envelope("portfolios" => [ envelope["portfolios"].first.merge(
          "transactions" => [ { "symbol" => "AAPL", "side" => "buy", "shares" => "abc",
                                "price" => nil, "executed_on" => "not-a-date" } ]
        ) ]))

        transaction = document.portfolios.first.transactions.first
        assert_nil transaction.shares
        assert_nil transaction.price
        assert_nil transaction.executed_on
        assert_equal BigDecimal(0), transaction.fees, "a missing fee is genuinely zero"
      end

      test "non-hash rows inside the arrays are ignored, not crashed on" do
        document = parse(envelope(
          "instruments" => [ "not a hash", 42, { "symbol" => "AAPL" } ],
          "portfolios" => [ envelope["portfolios"].first.merge("transactions" => [ nil, "x", 7 ]) ]
        ))

        assert_equal %w[AAPL], document.instruments.map(&:symbol)
        assert_empty document.portfolios.first.transactions
      end

      test "an instrument row with a blank symbol is dropped" do
        document = parse(envelope("instruments" => [ { "symbol" => "  " }, { "symbol" => "AAPL" } ]))

        assert_equal %w[AAPL], document.instruments.map(&:symbol)
      end

      test "missing optional arrays parse as empty, not nil" do
        document = parse(envelope("portfolios" => [ { "name" => "Bare" } ]))

        portfolio = document.portfolios.first
        assert_empty portfolio.transactions
        assert_empty portfolio.recurring_transactions
        assert_nil portfolio.benchmark_name
        assert_empty document.instruments if document.instruments.nil?
      end

      test "instrument_index keys on the upcased symbol" do
        document = parse(envelope)

        assert_equal "AAPL", document.instrument_index["AAPL"].symbol
      end

      test "detector routes a JSON body to this parser" do
        assert_equal NativeParser, Detector.new("  \n {\"format\": \"x\"}").parser
      end

      test "detector rejects a body that is neither JSON nor a holdings CSV" do
        error = assert_raises(UnreadableFile) { Detector.new("a,b,c\n1,2,3\n").parser }

        assert_includes error.message, "PortfolioView JSON export"
      end
    end
  end
end
