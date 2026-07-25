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
          portfolios: portfolios.reject { |spec| spec.transactions.empty? },
          warnings: warnings
        )
      end

      private

      # The single most important thing a user must know about this import, so it
      # is stated first and unhedged rather than left to the class comment.
      def synthesized_history_warning(as_of)
        "A holdings report has no trade history, so each position was imported as one opening buy " \
        "dated #{as_of.iso8601} priced at its book value per share. Total cost basis is preserved, " \
        "but purchase dates and individual lots are not — charts before #{as_of.iso8601} will be empty."
      end

      # One note for all of them. Emitting this per row produced thirteen
      # near-identical lines for a fourteen-row file, which buries the warnings
      # that are actually actionable.
      def requalified_warning(requalified)
        pairs = requalified.sort.map { |raw, qualified| "#{raw} → #{qualified}" }.join(", ")
        "#{requalified.size} non-US #{'listing'.pluralize(requalified.size)} were venue-suffixed so they " \
        "cannot be confused with the US ticker of the same name (#{pairs}). " \
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
          warnings: []
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
