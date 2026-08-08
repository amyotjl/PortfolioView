module Portfolios
  module Transfer
    # Parses the native export envelope back into a Document (backlog #064).
    #
    # This is a TRUST BOUNDARY: the file arrived over an upload form and may be
    # hand-edited, truncated, or hostile. Every scalar is coerced here (never in
    # Import), unknown keys are ignored, and anything unusable raises
    # UnreadableFile so the controller answers 422 on the `file` field. Per-row
    # problems that the DB would reject anyway are left to the model validations
    # so the user gets the same messages the transaction form gives.
    class NativeParser
      def self.call(...) = new(...).call

      def initialize(body)
        @body = body
      end

      def call
        envelope = parse_json
        validate_envelope!(envelope)

        Document.new(
          format: NATIVE_FORMAT,
          instruments: instrument_specs(envelope["instruments"]),
          portfolios: portfolio_specs(envelope["portfolios"]),
          warnings: []
        )
      end

      private

      def parse_json
        parsed = JSON.parse(@body)
        raise UnreadableFile, "must contain a JSON object" unless parsed.is_a?(Hash)

        parsed
      rescue JSON::ParserError => e
        # Don't echo the parser's raw message — it can quote file contents back
        # into an HTML-rendered error. Position alone is enough to locate it.
        raise UnreadableFile, "is not valid JSON#{json_position(e)}"
      end

      def json_position(error)
        match = error.message.match(/at line (\d+) column (\d+)/)
        match ? " (line #{match[1]}, column #{match[2]})" : ""
      end

      def validate_envelope!(envelope)
        format = envelope["format"].to_s
        unless format == NATIVE_FORMAT
          raise UnreadableFile,
                "is not a PortfolioView export (expected format #{NATIVE_FORMAT.inspect}, got #{format.presence.inspect})"
        end

        version = envelope["version"]
        unless SUPPORTED_VERSIONS.include?(version)
          raise UnreadableFile,
                "has unsupported version #{version.inspect} (this build reads #{SUPPORTED_VERSIONS.join(', ')})"
        end

        raise UnreadableFile, "has no \"portfolios\" array" unless envelope["portfolios"].is_a?(Array)
      end

      def instrument_specs(raw)
        return [] unless raw.is_a?(Array)

        raw.filter_map do |row|
          next unless row.is_a?(Hash)

          symbol = row["symbol"].to_s.strip
          next if symbol.blank?

          InstrumentSpec.build(
            symbol: symbol,
            name: row["name"],
            # An out-of-domain type would fail the CHECK constraint as a 500-ish
            # surprise later; normalize it here instead.
            instrument_type: %w[stock etf].include?(row["instrument_type"]) ? row["instrument_type"] : "stock",
            currency: row["currency"].presence || "USD",
            sector: row["sector"],
            industry: row["industry"]
          )
        end
      end

      def portfolio_specs(raw)
        raw.filter_map do |row|
          next unless row.is_a?(Hash)

          name = row["name"].to_s.strip
          raise UnreadableFile, "contains a portfolio with no name" if name.blank?

          PortfolioSpec.new(
            name: name,
            benchmark_name: row["benchmark"].presence,
            transactions: transaction_specs(row["transactions"]),
            recurring_transactions: recurring_specs(row["recurring_transactions"]),
            # Absent in a version-1 file, and absent from a version-2 file's
            # portfolios that hold no cash. Either way this yields [], the
            # portfolio is not cash-tracked, and every figure it reports is
            # exactly what a pre-#80 build reported. Back-compat is structural
            # here because the predicate is "has >= 1 cash row", not a flag.
            cash_transactions: cash_specs(row["cash_transactions"]),
            warnings: []
          )
        end
      end

      def transaction_specs(raw)
        return [] unless raw.is_a?(Array)

        raw.filter_map do |row|
          next unless row.is_a?(Hash)

          TransactionSpec.new(
            symbol: row["symbol"].to_s.strip.upcase,
            side: row["side"].to_s,
            kind: row["kind"].presence || "normal",
            shares: decimal(row["shares"]),
            price: decimal(row["price"]),
            fees: decimal(row["fees"]) || BigDecimal(0),
            executed_on: date(row["executed_on"]),
            notes: row["notes"].presence,
            recurring_key: row["recurring_key"].presence,
            scheduled_for: date(row["scheduled_for"])
          )
        end
      end

      # `amount` is read SIGNED and never coerced toward its kind's usual
      # direction: a negative dividend_cash and a positive tax are legal rows, so
      # a sign "correction" here would silently rewrite a reversal into a receipt.
      # A wrong sign for deposit/withdrawal is left to the model validation, which
      # mirrors the CHECK and reports on the `amount` field like every other bad
      # row in this parser.
      def cash_specs(raw)
        return [] unless raw.is_a?(Array)

        raw.filter_map do |row|
          next unless row.is_a?(Hash)

          CashSpec.new(
            kind: row["kind"].to_s.strip,
            amount: decimal(row["amount"]),
            occurred_on: date(row["occurred_on"]),
            notes: row["notes"].presence
          )
        end
      end

      def recurring_specs(raw)
        return [] unless raw.is_a?(Array)

        raw.each_with_index.filter_map do |row, index|
          next unless row.is_a?(Hash)

          RecurringSpec.new(
            # Fall back to positional keys so a hand-written file may omit them.
            key: row["key"].presence || "r#{index + 1}",
            symbol: row["symbol"].to_s.strip.upcase,
            side: row["side"].presence || "buy",
            amount_type: row["amount_type"].to_s,
            dollar_amount: decimal(row["dollar_amount"]),
            share_amount: decimal(row["share_amount"]),
            frequency: row["frequency"].to_s,
            anchor_on: date(row["anchor_on"]),
            next_run_on: date(row["next_run_on"]),
            end_on: date(row["end_on"]),
            # Default true: a file that omits the flag means an ordinary rule.
            active: row["active"].nil? ? true : ActiveModel::Type::Boolean.new.cast(row["active"])
          )
        end
      end

      # nil (not 0) for a missing/garbage value, so the model validation reports
      # "can't be blank" rather than silently importing a zero-share trade.
      def decimal(value)
        return nil if value.nil?
        return value if value.is_a?(BigDecimal)

        string = value.to_s.strip
        return nil if string.blank?

        BigDecimal(string)
      rescue ArgumentError, TypeError
        nil
      end

      def date(value)
        string = value.to_s.strip
        return nil if string.blank?

        Date.iso8601(string)
      rescue Date::Error
        nil
      end
    end
  end
end
