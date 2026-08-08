require "csv"

module Portfolios
  module Transfer
    # Parses a broker HOLDINGS SNAPSHOT csv (the user-supplied Wealthsimple
    # "holdings-report.csv" shape) into a Document.
    #
    # ---------------------------------------------------------------------------
    # READ THIS BEFORE TRUSTING AN IMPORTED COST BASIS
    #
    # A holdings report is not a ledger. It says what you hold *now*, not how you
    # got there — no trade dates, no individual fills, no fees, no closed
    # positions. So this parser SYNTHESIZES one opening `buy` per position:
    #
    #   shares      = Quantity
    #   price       = Book Value (Market) / Quantity   <- cost basis per share
    #   fees        = 0                                <- not in the report
    #   executed_on = the report's "As of <date>" trailer
    #
    # Each synthesized buy is paired with an OFFSETTING `deposit` of the same
    # dollars on the same date (issue #80). The buy would otherwise debit cash the
    # user never spent, and a snapshot has no deposit rows to fund it from. Because
    # every offset is same-date and same-dollar as its buy, the portfolio's cash
    # lands at exactly 0.00, net_deposits equals total book value — the same figure
    # the trade basis produced before there was a cash ledger — and every synthetic
    # benchmark trade still lands on the same date for the same dollars, so
    # benchmark_return_pct does not move either. A snapshot import's numbers are
    # provably unchanged while its basis becomes cash.
    #
    # Consequences the UI states plainly and that a reader of this code must not
    # forget:
    #   * Total cost basis is preserved (that is why Book Value is divided rather
    #     than Market Price used), so /summary's net_deposits and total_return are
    #     right as of the report date.
    #   * The HISTORY is fiction. Every position appears to have been bought in
    #     one lot on the report date, so any chart window starting before that
    #     date is empty, and per-lot holding periods are lost.
    #   * A position closed before the report date is absent entirely.
    #
    # This is the most faithful reading available from the file; a real trade
    # history needs a broker ACTIVITY/transactions export, not a holdings report.
    # ---------------------------------------------------------------------------
    class HoldingsCsvParser
      # Columns that must all be present for us to claim this shape. Deliberately
      # the smallest set the parser actually needs, so a broker that adds or drops
      # unrelated columns still imports.
      REQUIRED_HEADERS = [ "Account Name", "Symbol", "Quantity" ].freeze

      # Book value is preferred (cost basis); market value would restate the
      # portfolio as if bought at today's price, destroying all gain/loss.
      BOOK_VALUE_HEADERS = [ "Book Value (Market)", "Book Value (CAD)", "Book Value" ].freeze

      # transactions.price is numeric(16,6) and shares numeric(20,8); the report
      # carries far longer quotients (one book value has 24 decimals), so both are
      # rounded to their column scale here rather than letting PG truncate.
      PRICE_SCALE = 6
      SHARES_SCALE = 8

      SECURITY_TYPE_MAP = {
        "EXCHANGE_TRADED_FUND" => "etf",
        "ETF" => "etf",
        "MUTUAL_FUND" => "etf",
        "EQUITY" => "stock",
        "STOCK" => "stock",
        "COMMON_STOCK" => "stock"
      }.freeze

      # "As of 2026-07-25 10:23 GMT-04:00" — a trailing single-cell row.
      AS_OF_PATTERN = /\bAs of\s+(\d{4}-\d{2}-\d{2})/i

      def self.call(...) = new(...).call

      def initialize(body, today: Trading::Calendar.today)
        @body = body
        @today = today
      end

      def call
        table = parse_csv
        as_of, as_of_warning = resolve_as_of(table)

        rows = table.select { |row| row["Account Name"].present? && row["Symbol"].present? }
        raise UnreadableFile, "contains no holdings rows" if rows.empty?

        instruments = {}
        warnings = []
        warnings << as_of_warning if as_of_warning
        warnings << synthesized_history_warning(as_of)

        # raw ticker => qualified symbol, for the single consolidated note below.
        requalified = {}

        grouped = rows.group_by { |row| row["Account Name"].to_s.strip }
        portfolios = grouped.map do |account_name, account_rows|
          build_portfolio(account_name, account_rows, as_of, instruments, warnings, requalified)
        end

        warnings << requalified_warning(requalified) if requalified.any?

        Document.new(
          format: HOLDINGS_CSV_FORMAT,
          instruments: instruments.values,
          # A portfolio can end up with no usable rows (all shorts / all zero
          # quantity); dropping it beats creating an empty portfolio the user
          # then has to delete. The reason is already in `warnings`.
          #
          # Cash is checked too, for symmetry with ActivitiesCsvParser: here every
          # cash row is an offset for a transaction, so the two conditions cannot
          # disagree — but a predicate that ONLY looks at transactions is the shape
          # that silently discards money in the parser that can produce cash-only
          # accounts, and one predicate is easier to keep right than two.
          portfolios: portfolios.reject { |spec| spec.transactions.empty? && spec.cash_transactions.empty? },
          warnings: warnings
        )
      end

      private

      # The single most important thing a user must know about this import, so it
      # is stated first and unhedged rather than left to the class comment.
      #
      # Wording here is TENSE-NEUTRAL: the same strings are shown for a dry run,
      # where nothing has been written yet.
      def synthesized_history_warning(as_of)
        "A holdings report has no trade history, so each position becomes one opening buy " \
        "dated #{as_of.iso8601} priced at its book value per share, funded by a matching deposit on the " \
        "same day. Total cost basis is preserved and the cash balance is zero, " \
        "but purchase dates and individual lots are not — charts before #{as_of.iso8601} will be empty."
      end

      # One note for all of them. Emitting this per row produced thirteen
      # near-identical lines for a fourteen-row file, which buries the warnings
      # that are actually actionable.
      def requalified_warning(requalified)
        pairs = requalified.sort.map { |raw, qualified| "#{raw} → #{qualified}" }.join(", ")
        one = requalified.size == 1
        "#{requalified.size} non-US #{one ? 'listing is' : 'listings are'} " \
        "venue-suffixed so #{one ? 'it cannot' : 'they cannot'} be confused with the US ticker of the same name (#{pairs}). " \
        "Price history is unavailable for these symbols — the provider directory covers US listings only — " \
        "so their market value will read as zero until a non-US price source is configured."
      end

      def parse_csv
        # liberal_parsing so a stray unescaped quote degrades to a literal
        # character instead of aborting a 200-row file.
        CSV.parse(@body, headers: true, liberal_parsing: true)
      rescue CSV::MalformedCSVError => e
        raise UnreadableFile, "is not readable CSV (#{e.message.split("\n").first})"
      end

      def build_portfolio(account_name, rows, as_of, instruments, warnings, requalified)
        transactions = rows.filter_map do |row|
          transaction_for(row, account_name, as_of, instruments, warnings, requalified)
        end

        PortfolioSpec.new(
          name: account_name,
          # Holdings reports carry no benchmark concept; the user picks one after
          # import via the portfolio edit dialog.
          benchmark_name: nil,
          transactions: transactions,
          recurring_transactions: [],
          cash_transactions: transactions.filter_map { |tx| opening_deposit_for(tx) },
          warnings: []
        )
      end

      # The offsetting deposit for ONE synthesized opening buy — see the class
      # header for why it exists and what it buys us.
      #
      # The amount is reconstructed from the SPEC (shares x price), not taken from
      # the report's book value, so it equals what Portfolios::TradeCash will
      # charge for that buy to the cent. `price` is book value / quantity rounded
      # to 6 dp (one book value in the real report carries 24 decimals), so the raw
      # book value can differ from the trade's actual cash effect by a fraction of
      # a cent — and cash that drifts by pennies is exactly what this feature
      # exists to stop.
      def opening_deposit_for(tx)
        amount = MoneyMath.round_to_cents(tx.shares * tx.price)
        # amount <> 0 is a CHECK, and a zero deposit would abort the whole
        # portfolio's savepoint. A position this small has a trade cash effect of
        # 0.00 too, so skipping it still nets to zero.
        return nil if amount.zero?

        CashSpec.new(
          kind: "deposit",
          amount: amount,
          # SAME DATE as its buy, deliberately. A day either side leaves the
          # balance at zero but moves the benchmark's synthetic fill onto a
          # different close, silently changing benchmark_return_pct.
          occurred_on: tx.executed_on,
          notes: "Offsets the synthesized opening buy: a holdings report has no deposit history, so the " \
                 "cash that funded this position is recorded on the same day for the same amount. The " \
                 "position's cost basis is contributed capital; the net cash effect is zero."
        )
      end

      def transaction_for(row, account_name, as_of, instruments, warnings, requalified)
        raw_symbol = row["Symbol"].to_s.strip
        label = "#{account_name} / #{raw_symbol}"

        direction = row["Position Direction"].to_s.strip.upcase
        if direction.present? && direction != "LONG"
          # v1 has no short positions (PLAN.md) and Positions::Validator would
          # reject the synthesized trade anyway — skip loudly, never silently.
          warnings << "#{label}: skipped — #{direction.downcase} positions are not supported."
          return nil
        end

        shares = decimal(row["Quantity"])&.round(SHARES_SCALE)
        if shares.nil? || shares <= 0
          warnings << "#{label}: skipped — quantity #{row['Quantity'].to_s.strip.presence || '(blank)'} is not a positive number."
          return nil
        end

        book_value = book_value_for(row)
        if book_value.nil? || book_value <= 0
          warnings << "#{label}: skipped — no positive book value to derive a cost basis from."
          return nil
        end

        price = (book_value / shares).round(PRICE_SCALE)
        if price <= 0
          # Possible for a sub-cent unit cost: rounding to 6dp floors it to zero,
          # and transactions.price has a `> 0` CHECK constraint.
          warnings << "#{label}: skipped — derived unit cost rounds to zero at 6 decimal places."
          return nil
        end

        symbol = qualified_symbol(row, raw_symbol)
        instruments[symbol] ||= instrument_spec(row, symbol)
        requalified[raw_symbol.upcase] = symbol if symbol != raw_symbol.upcase

        TransactionSpec.new(
          symbol: symbol,
          side: "buy",
          kind: "normal",
          shares: shares,
          price: price,
          fees: BigDecimal(0),
          executed_on: as_of,
          notes: provenance_note(as_of),
          recurring_key: nil,
          scheduled_for: nil
        )
      end

      def provenance_note(as_of)
        "Imported from a broker holdings report (as of #{as_of.iso8601}). " \
        "Synthesized opening position: cost basis = book value / quantity; the trade date is the report date, not the real purchase date."
      end

      def qualified_symbol(row, raw_symbol)
        SymbolQualifier.call(
          symbol: raw_symbol,
          mic: row["MIC"],
          exchange: row["Exchange"],
          currency: row["Market Price Currency"] || row["Market Value Currency"]
        )
      end

      def instrument_spec(row, symbol)
        InstrumentSpec.build(
          symbol: symbol,
          name: row["Name"].to_s.strip,
          instrument_type: SECURITY_TYPE_MAP.fetch(row["Security Type"].to_s.strip.upcase, "stock"),
          currency: (row["Market Price Currency"] || row["Market Value Currency"]).to_s.strip.upcase.presence || "USD"
        )
      end

      def book_value_for(row)
        BOOK_VALUE_HEADERS.lazy.filter_map { |header| decimal(row[header]) }.first
      end

      # The "As of" trailer sits in a row of its own after a blank line, so it
      # lands in the table as a row whose first field holds the whole string.
      def resolve_as_of(table)
        candidate = table.each.filter_map { |row| row.fields.compact.find { |f| f.match?(AS_OF_PATTERN) } }.first
        candidate ||= @body.lines.reverse.find { |line| line.match?(AS_OF_PATTERN) }

        match = candidate&.match(AS_OF_PATTERN)
        return [ Date.iso8601(match[1]), nil ] if match

        [ @today,
          "The report has no \"As of\" date, so #{@today.iso8601} was used as the opening trade date for every position." ]
      rescue Date::Error
        [ @today,
          "The report's \"As of\" date could not be read, so #{@today.iso8601} was used as the opening trade date." ]
      end

      def decimal(value)
        string = value.to_s.strip
        return nil if string.blank?

        # Tolerate thousands separators, currency symbols, and parenthesized
        # negatives — all seen in broker CSV exports.
        negative = string.start_with?("(") && string.end_with?(")")
        cleaned = string.gsub(/[()\s,$]/, "")
        return nil if cleaned.blank?

        result = BigDecimal(cleaned)
        negative ? -result : result
      rescue ArgumentError, TypeError
        nil
      end
    end
  end
end
