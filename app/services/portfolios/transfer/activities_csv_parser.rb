require "csv"

module Portfolios
  module Transfer
    # Parses a broker ACTIVITY LEDGER csv (the Wealthsimple activities export)
    # into a Document — backlog #068.
    #
    # This is the format to prefer when a user has both: unlike the holdings
    # snapshot HoldingsCsvParser reads, this is a real transaction history, so
    # trade dates, individual fills and closed positions all survive.
    #
    # ---------------------------------------------------------------------------
    # ACTIVITY MAPPING
    #
    #   Trade/BUY             -> buy   (shares=quantity, price=unit_price, fees=commission)
    #   Trade/SELL            -> sell  (quantity is NEGATIVE in the file; abs it)
    #   SecurityTransfer      -> buy/sell by quantity sign, priced at
    #                            net_cash_amount / quantity. These are real
    #                            positions moved in from another institution and
    #                            are worth five figures in the sample file —
    #                            dropping them would silently lose a third of a
    #                            portfolio.
    #   CorporateAction/SUBDIVISION -> a SplitEvent. See #split_from below.
    #
    #   Dividend, Interest, MoneyMovement, Tax, AdministrativePayment -> SKIPPED.
    #
    # WHY THE CASH ROWS ARE SKIPPED, and what it costs.
    #
    # This app models instrument positions only; there is no cash account
    # (docs/PLAN.md). Deposits, dividends received, interest and tax withholding
    # have nowhere to go. Two consequences the report states plainly rather than
    # leaving the user to discover:
    #
    #   * net_deposits is derived from TRADE COST, not from the deposit rows. The
    #     two agree only if every deposit was fully invested.
    #   * a buy funded by a dividend reads as a NEW external contribution, so
    #     total return is understated by the reinvested amount. (Marking such buys
    #     `dividend_reinvestment` would fix the math, but pairing a dividend to a
    #     later buy by amount is guesswork, and guessing wrong misstates a money
    #     figure. Left to the user, who can edit `kind` per transaction.)
    #
    # SYMBOL VENUE — there is no MIC or Exchange column in this export.
    #
    # The `currency` column is the ACCOUNT's currency (CAD on every row of the
    # sample) and says nothing about where a security is listed. The real signal
    # is an "FX Rate:" marker in a TRADE's description: the broker converted
    # currency to settle it, so the security is not CAD-denominated and is
    # therefore a US listing that keeps its bare ticker. Its absence means a
    # CAD-listed security, which gets a venue suffix so it cannot alias the US
    # ticker of the same name.
    #
    # This correctly separates the US `QQQ` from the CAD-listed `QQC`/`XQQ`, and
    # correctly suffixes the CAD-hedged `META`/`GOOG` CDRs — which are entirely
    # different securities from NASDAQ's META and GOOG.
    #
    # The verdict is reached PER SYMBOL over the whole file, not per row, because
    # only trades carry the marker while dividends, transfers and corporate
    # actions for the same symbol do not.
    # ---------------------------------------------------------------------------
    class ActivitiesCsvParser
      # The smallest set that identifies this shape, so an added or dropped
      # unrelated column doesn't stop the file importing.
      REQUIRED_HEADERS = %w[transaction_date account_type activity_type quantity].freeze

      # Column scales: transactions.price is numeric(16,6), shares numeric(20,8),
      # fees numeric(12,2), split_events.ratio numeric(12,6). The file carries
      # unit prices to 10 decimals, so rounding happens here rather than letting
      # PostgreSQL truncate.
      PRICE_SCALE = 6
      SHARES_SCALE = 8
      FEES_SCALE = 2
      RATIO_SCALE = 6

      # "…, FX Rate: 1.4199" — the broker converted currency to settle the trade.
      FX_MARKER = /\bFX Rate:/i

      TRADE = "Trade".freeze
      SECURITY_TRANSFER = "SecurityTransfer".freeze
      CORPORATE_ACTION = "CorporateAction".freeze

      # Cash-only activity: real events with no representation in this schema.
      # Mapped to the wording used in the skip report, SINGULAR — the report
      # pluralizes by count, so "1 dividend payment" and "62 dividend payments"
      # both read correctly.
      CASH_ACTIVITIES = {
        "Dividend" => "dividend payment",
        "Interest" => "interest payment",
        "MoneyMovement" => "cash movement",
        "Tax" => "tax withholding",
        "AdministrativePayment" => "administrative credit"
      }.freeze

      def self.call(...) = new(...).call

      def initialize(body)
        @body = body
      end

      def call
        rows = parse_csv
        raise UnreadableFile, "contains no activity rows" if rows.empty?

        # Pass 1: decide each symbol's venue once, from the whole file.
        @foreign = foreign_symbols(rows)
        @qualified = {}

        instruments = {}
        warnings = []
        skipped = Hash.new { |h, k| h[k] = { count: 0, total: BigDecimal(0) } }
        requalified = {}

        by_account = rows.group_by { |row| row["account_type"].to_s.strip }
        portfolios = by_account.map do |account, account_rows|
          build_portfolio(account, account_rows, instruments, skipped, requalified)
        end

        # Pass 3: splits, after the trades are known — the ratio is derived from
        # the share position the ledger itself implies at the ex-date.
        splits = build_splits(rows, portfolios, warnings, instruments, requalified)

        warnings.unshift(*ledger_warnings(skipped))
        warnings << requalified_warning(requalified) if requalified.any?

        Document.new(
          format: ACTIVITIES_CSV_FORMAT,
          instruments: instruments.values,
          portfolios: portfolios.reject { |spec| spec.transactions.empty? },
          warnings: warnings,
          splits: splits
        )
      end

      private

      def parse_csv
        table = CSV.parse(@body, headers: true, liberal_parsing: true)
        table.select { |row| row["transaction_date"].present? && row["activity_type"].present? }
      rescue CSV::MalformedCSVError => e
        raise UnreadableFile, "is not readable CSV (#{e.message.split("\n").first})"
      end

      # Symbols the file shows being settled through an FX conversion — i.e. not
      # denominated in the account's currency, so US-listed.
      def foreign_symbols(rows)
        rows.each_with_object(Set.new) do |row, set|
          next unless row["activity_type"].to_s.strip == TRADE
          next if row["symbol"].blank?
          set << row["symbol"].to_s.strip.upcase if row["description"].to_s.match?(FX_MARKER)
        end
      end

      def qualify(raw_symbol, requalified)
        key = raw_symbol.to_s.strip.upcase
        return @qualified[key] if @qualified.key?(key)

        qualified =
          if @foreign.include?(key)
            key
          else
            SymbolQualifier.call(symbol: key, assume_non_us: true)
          end

        requalified[key] = qualified if qualified != key
        @qualified[key] = qualified
      end

      def build_portfolio(account, rows, instruments, skipped, requalified)
        transactions = rows.filter_map do |row|
          transaction_for(row, instruments, skipped, requalified)
        end

        PortfolioSpec.new(
          name: account,
          # An activity ledger carries no benchmark concept; the user picks one
          # after import from the portfolio edit dialog.
          benchmark_name: nil,
          transactions: transactions,
          recurring_transactions: [],
          warnings: []
        )
      end

      def transaction_for(row, instruments, skipped, requalified)
        case row["activity_type"].to_s.strip
        when TRADE             then trade_for(row, instruments, requalified)
        when SECURITY_TRANSFER then transfer_for(row, instruments, requalified)
        when CORPORATE_ACTION  then nil  # handled by #build_splits
        else
          record_skip(row, skipped)
          nil
        end
      end

      def record_skip(row, skipped)
        activity = row["activity_type"].to_s.strip
        label = CASH_ACTIVITIES[activity] || "#{activity} row"
        bucket = skipped[label]
        bucket[:count] += 1
        # net_cash_amount is the signed cash effect; the magnitude is what makes
        # the skip report meaningful ("62 dividend payments totalling $431.28").
        amount = decimal(row["net_cash_amount"]) || decimal(row["quantity"])
        bucket[:total] += amount.abs if amount
      end

      def trade_for(row, instruments, requalified)
        raw_symbol = row["symbol"].to_s.strip
        return nil if raw_symbol.blank?

        quantity = decimal(row["quantity"])
        price = decimal(row["unit_price"])
        return nil if quantity.nil? || quantity.zero? || price.nil? || price <= 0

        sell = row["activity_sub_type"].to_s.strip.upcase == "SELL" || quantity.negative?
        symbol = qualify(raw_symbol, requalified)
        instruments[symbol] ||= instrument_spec(row, symbol)

        TransactionSpec.new(
          symbol: symbol,
          side: sell ? "sell" : "buy",
          kind: "normal",
          # SELL rows carry a NEGATIVE quantity; shares has a `> 0` CHECK.
          shares: quantity.abs.round(SHARES_SCALE),
          price: price.round(PRICE_SCALE),
          fees: (decimal(row["commission"]) || BigDecimal(0)).abs.round(FEES_SCALE),
          # transaction_date is the trade date; settlement_date is 2 days later
          # for some brokers and would shift every trade off its real day.
          executed_on: date(row["transaction_date"]),
          notes: nil,
          recurring_key: nil,
          scheduled_for: nil
        )
      end

      # A transfer in/out of the account: real shares arriving or leaving, with
      # their market value in net_cash_amount but no unit price. Priced at
      # value/quantity, which makes an incoming transfer economically identical to
      # depositing that cash and buying at that price — the right reading for a
      # value-tracking app.
      def transfer_for(row, instruments, requalified)
        raw_symbol = row["symbol"].to_s.strip
        return nil if raw_symbol.blank?

        quantity = decimal(row["quantity"])
        value = decimal(row["net_cash_amount"])
        return nil if quantity.nil? || quantity.zero? || value.nil? || value.zero?

        price = (value.abs / quantity.abs).round(PRICE_SCALE)
        return nil if price <= 0

        symbol = qualify(raw_symbol, requalified)
        instruments[symbol] ||= instrument_spec(row, symbol)

        TransactionSpec.new(
          symbol: symbol,
          side: quantity.negative? ? "sell" : "buy",
          kind: "normal",
          shares: quantity.abs.round(SHARES_SCALE),
          price: price,
          fees: BigDecimal(0),
          executed_on: date(row["transaction_date"]),
          notes: "Imported from a broker activity ledger: #{quantity.negative? ? 'transfer out of' : 'transfer into'} " \
                 "the account, valued at #{price.to_s('F')} per share (the ledger carries no unit price).",
          recurring_key: nil,
          scheduled_for: nil
        )
      end

      # --- Corporate actions -----------------------------------------------------

      # SUBDIVISION arrives as a SHARE DELTA with no price and no cash:
      #
      #   "ZEQT - BMO All-Equity ETF: Corrected quantity of shares by 182.0398"
      #
      # A split is a RATIO, so the ratio is recovered from the position the ledger
      # itself implies immediately before the ex-date:
      #
      #   ratio = (position + delta) / position
      #
      # In the sample file that is (91.0199 + 182.0398) / 91.0199 = exactly 3.
      #
      # It cannot be a transaction: shares have a `price > 0` CHECK, and any price
      # would inject phantom cash into net_deposits. A SplitEvent is the correct
      # home — Holdings::Calculator already multiplies the running position by the
      # ratio at the START of the ex-date, before same-day trades, which is
      # precisely the basis the ledger uses (a pre-split buy at the pre-split
      # price, then post-split buys at the post-split price).
      def build_splits(rows, portfolios, warnings, instruments, requalified)
        action_rows = rows.select { |row| row["activity_type"].to_s.strip == CORPORATE_ACTION }
        return [] if action_rows.empty?

        # A split is instrument-global, so the same event appears once per account
        # holding the instrument. Collapse them by (symbol, ex_date), and refuse
        # to guess when two accounts imply different ratios.
        accepted = {}
        conflicted = Set.new

        action_rows.each do |row|
          spec = split_from(row, portfolios, warnings, instruments, requalified)
          next if spec.nil?

          key = [ spec.symbol, spec.ex_date ]
          next if conflicted.include?(key)

          seen = accepted[key]
          if seen.nil?
            accepted[key] = spec
          elsif seen.ratio != spec.ratio
            warnings << "#{spec.symbol}: two accounts imply different split ratios on " \
                        "#{spec.ex_date.iso8601} (#{seen.ratio.to_s('F')} and #{spec.ratio.to_s('F')}), " \
                        "so no split was recorded. Add it manually."
            accepted.delete(key)
            conflicted << key
          end
        end

        accepted.values
      end

      def split_from(row, portfolios, warnings, instruments, requalified)
        raw_symbol = row["symbol"].to_s.strip
        account = row["account_type"].to_s.strip
        sub_type = row["activity_sub_type"].to_s.strip
        ex_date = date(row["transaction_date"])
        delta = decimal(row["quantity"])
        label = "#{account} / #{raw_symbol.presence || '(no symbol)'}"

        if raw_symbol.blank? || ex_date.nil? || delta.nil? || delta.zero?
          warnings << "#{label}: a #{sub_type.presence || 'corporate action'} row could not be read " \
                      "(needs a symbol, a date and a share change), so it was skipped."
          return nil
        end

        symbol = qualify(raw_symbol, requalified)
        instruments[symbol] ||= instrument_spec(row, symbol)

        position = position_before(portfolios, account, symbol, ex_date)
        if position.nil? || position <= 0
          warnings << "#{label}: a share adjustment of #{delta.to_s('F')} on #{ex_date.iso8601} was skipped — " \
                      "the ledger shows no position before that date to derive a split ratio from. " \
                      "The resulting share count will be short by #{delta.to_s('F')}."
          return nil
        end

        ratio = ((position + delta) / position).round(RATIO_SCALE)
        if ratio <= 0
          warnings << "#{label}: a share adjustment of #{delta.to_s('F')} on #{ex_date.iso8601} implies a " \
                      "non-positive split ratio, so it was skipped."
          return nil
        end

        warnings << "#{symbol}: a #{sub_type.presence || 'corporate action'} of #{delta.to_s('F')} shares on " \
                    "#{ex_date.iso8601} was recorded as a #{ratio.to_s('F')}:1 split " \
                    "(the position was #{position.to_s('F')} immediately before). " \
                    "Splits apply to every portfolio holding #{symbol}."
        SplitSpec.new(symbol: symbol, ex_date: ex_date, ratio: ratio)
      end

      # The share position one account's ledger implies for a symbol strictly
      # BEFORE ex_date. Splits already derived are not applied: a second split for
      # the same symbol would need them, which is out of scope until a file
      # actually contains one (and would be reported as an unreadable ratio rather
      # than silently mis-derived, because the position would not reconcile).
      def position_before(portfolios, account, symbol, ex_date)
        portfolio = portfolios.find { |spec| spec.name == account }
        return nil if portfolio.nil?

        portfolio.transactions
                 .select { |tx| tx.symbol == symbol && tx.executed_on && tx.executed_on < ex_date }
                 .sum(BigDecimal(0)) { |tx| tx.side == "sell" ? -tx.shares : tx.shares }
      end

      # --- Instrument identity ---------------------------------------------------

      # No asset_type column, so the type is inferred from the security NAME.
      # Only cosmetic in this app (nothing in valuation reads instrument_type),
      # and an instrument that already exists is never rewritten from a file.
      FUND_NAME = /\b(ETF|Fund|Index|Trust|Portfolio)\b|iShares|Vanguard/i

      def instrument_spec(row, symbol)
        name = row["name"].to_s.strip
        # A US listing settled through FX is denominated in USD; everything else
        # in this export is denominated in the account's currency.
        currency = @foreign.include?(row["symbol"].to_s.strip.upcase) ? "USD" : account_currency(row)

        InstrumentSpec.build(
          symbol: symbol,
          name: name,
          instrument_type: name.match?(FUND_NAME) ? "etf" : "stock",
          currency: currency
        )
      end

      def account_currency(row)
        row["currency"].to_s.strip.upcase.presence || "CAD"
      end

      # --- Warnings --------------------------------------------------------------

      def ledger_warnings(skipped)
        notes = []
        if skipped.any?
          summary = skipped.sort_by { |label, _| label }.map do |label, data|
            amount = data[:total].positive? ? " totalling #{money(data[:total])}" : ""
            "#{data[:count]} #{label.pluralize(data[:count])}#{amount}"
          end
          notes << "This app tracks instrument positions, not a cash balance, so #{summary.to_sentence} " \
                   "#{skipped.values.sum { |d| d[:count] } == 1 ? 'was' : 'were'} skipped."
        end
        if skipped.key?("dividend payment") || skipped.key?("cash movement")
          notes << "Two consequences worth knowing: contributed capital is derived from what you actually " \
                   "bought rather than from the deposit rows, and a purchase funded by a dividend counts as " \
                   "a new contribution — which understates return by the reinvested amount. Set a " \
                   "transaction's kind to “dividend reinvestment” to correct any you care about."
        end
        notes
      end

      # A real ledger renames dozens of tickers (39 in the sample file), so the
      # mapping list is capped — an unreadable paragraph buries the two sentences
      # that actually matter, and the suffixed symbols are visible on every row of
      # the transactions table anyway.
      EXAMPLE_LIMIT = 8

      def requalified_warning(requalified)
        sorted = requalified.sort
        shown = sorted.first(EXAMPLE_LIMIT).map { |raw, qualified| "#{raw} → #{qualified}" }.join(", ")
        rest = sorted.size - EXAMPLE_LIMIT
        examples = rest.positive? ? "#{shown}, and #{rest} more" : shown
        one = sorted.size == 1

        "#{sorted.size} non-US #{one ? 'listing is' : 'listings are'} " \
        "venue-suffixed so #{one ? 'it cannot' : 'they cannot'} be confused with the US ticker of the same name " \
        "(#{examples}). This export has no exchange column, so the venue is inferred from the absence of an " \
        "FX conversion on the trade. Price history is unavailable for these symbols — the provider directory " \
        "covers US listings only — so their market value will read as zero until a non-US price source is " \
        "configured."
      end

      # --- Scalars ---------------------------------------------------------------

      # No currency symbol: the ledger's amounts are in the account's currency,
      # which varies, and guessing "$" would be wrong for a CAD account.
      def money(amount)
        ActiveSupport::NumberHelper.number_to_rounded(amount, precision: 2, delimiter: ",")
      end

      def decimal(value)
        string = value.to_s.strip
        return nil if string.blank?

        negative = string.start_with?("(") && string.end_with?(")")
        cleaned = string.gsub(/[()\s,$]/, "")
        return nil if cleaned.blank?

        result = BigDecimal(cleaned)
        negative ? -result : result
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
