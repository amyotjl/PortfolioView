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
    #   MoneyMovement         -> deposit (net > 0) / withdrawal (net < 0)
    #   Dividend              -> dividend_cash
    #   Interest              -> interest
    #   Tax                   -> tax
    #   AdministrativePayment -> fee
    #
    # THE CASH ROWS ARE INGESTED (issue #80). Every one of them lands in the
    # portfolio's cash ledger, which is what makes the app's total comparable to
    # the broker's statement instead of holdings-only. Consequences, stated here
    # because they are the whole point of reading this file rather than a holdings
    # snapshot:
    #
    #   * net_deposits comes from the DEPOSIT ROWS, not from trade cost. Idle cash
    #     is therefore visible instead of being invisible, and the benchmark — fed
    #     the same deposits on the same dates — correctly penalizes it.
    #   * a buy funded by a dividend no longer reads as a new external
    #     contribution. The dividend arrives as `dividend_cash` (internal, not a
    #     contribution), the buy debits cash, net_deposits does not move, and the
    #     gain lands in return. This is a defect #68 shipped with, fixed for free
    #     by having somewhere to put the cash; no per-transaction `kind` editing.
    #   * amount is net_cash_amount SIGNED and verbatim. A negative Dividend is a
    #     real reversal and a positive Tax is a real refund; taking a magnitude
    #     anywhere here would silently invert both.
    #   * a row whose net_cash_amount is nil or zero is DROPPED with a warning —
    #     the amount CHECK forbids zero, and one skipped no-op row beats failing
    #     the user's whole portfolio.
    #
    # Trade/BUY, Trade/SELL and CorporateAction/SUBDIVISION produce NO cash row:
    # a trade's cash effect is derived from the trade itself by Portfolios::
    # CashLedger (double-counting it here would debit every purchase twice), and a
    # split moves shares, not money.
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

      # Cash activity -> the CashTransaction kind it becomes (issue #80). This was
      # a SKIP LIST until there was a cash ledger to put the rows in.
      #
      # BY_SIGN is MoneyMovement only: one broker activity that is a deposit or a
      # withdrawal depending on which way the money went. The other four each map
      # to exactly one kind and carry their own sign inside it (a Tax refund is a
      # positive `tax`; an AdministrativePayment charge is a negative `fee`).
      BY_SIGN = :by_sign

      CASH_ACTIVITIES = {
        "MoneyMovement" => BY_SIGN,
        "Dividend" => "dividend_cash",
        "Interest" => "interest",
        "Tax" => "tax",
        "AdministrativePayment" => "fee"
      }.freeze

      # Report wording, SINGULAR — the report pluralizes by count, so "1 dividend
      # payment" and "62 dividend payments" both read correctly.
      CASH_LABELS = {
        "MoneyMovement" => "cash movement",
        "Dividend" => "dividend payment",
        "Interest" => "interest payment",
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
        tally = new_tally
        requalified = {}

        by_account = rows.group_by { |row| row["account_type"].to_s.strip }
        portfolios = by_account.map do |account, account_rows|
          build_portfolio(account, account_rows, instruments, tally, requalified)
        end

        # Pass 3: splits, after the trades are known — the ratio is derived from
        # the share position the ledger itself implies at the ex-date.
        splits = build_splits(rows, portfolios, warnings, instruments, requalified)

        warnings.unshift(*ledger_warnings(tally))
        warnings << requalified_warning(requalified) if requalified.any?

        Document.new(
          format: ACTIVITIES_CSV_FORMAT,
          instruments: instruments.values,
          # An account with no usable rows at all is dropped rather than imported
          # empty. CASH COUNTS AS A USABLE ROW (issue #80): an account holding only
          # a deposit is a real account with real money in it, and dropping it here
          # would silently discard that money — the exact failure this feature
          # exists to end. Before there was a cash ledger, transactions were the
          # only thing a portfolio could be made of.
          portfolios: portfolios.reject { |spec| spec.transactions.empty? && spec.cash_transactions.empty? },
          warnings: warnings,
          splits: splits
        )
      end

      private

      # Three separate accumulators because they say three different things and
      # only the first is good news:
      #   cash       activity label => rows ingested into the cash ledger
      #   dropped    activity label => cash rows with no usable amount
      #   skipped    activity label => activity types this build does not know
      def new_tally
        {
          cash: Hash.new { |h, k| h[k] = { count: 0, total: BigDecimal(0) } },
          dropped: Hash.new(0),
          skipped: Hash.new { |h, k| h[k] = { count: 0, total: BigDecimal(0) } }
        }
      end

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

      # One pass per account producing BOTH lists: the trades, and the cash rows
      # (the ledger's own cash activity plus the offsetting movements the
      # synthesized transfer trades require).
      def build_portfolio(account, rows, instruments, tally, requalified)
        transactions = []
        cash = []

        rows.each do |row|
          case row["activity_type"].to_s.strip
          when TRADE
            # No cash row: Portfolios::CashLedger derives a trade's cash effect
            # from the trade. Emitting one here would debit every purchase twice.
            tx = trade_for(row, instruments, requalified)
            transactions << tx if tx
          when SECURITY_TRANSFER
            tx = transfer_for(row, instruments, requalified)
            next if tx.nil?

            transactions << tx
            offset = transfer_offset_for(tx)
            cash << offset if offset
          when CORPORATE_ACTION
            # Handled by #build_splits. A split moves shares, not money.
            nil
          else
            spec = cash_for(row, tally)
            cash << spec if spec
          end
        end

        PortfolioSpec.new(
          name: account,
          # An activity ledger carries no benchmark concept; the user picks one
          # after import from the portfolio edit dialog.
          benchmark_name: nil,
          transactions: transactions,
          recurring_transactions: [],
          cash_transactions: cash,
          warnings: []
        )
      end

      # A ledger cash row -> a CashSpec, or nil when this build does not recognize
      # the activity or the row carries no money.
      def cash_for(row, tally)
        activity = row["activity_type"].to_s.strip
        mapped = CASH_ACTIVITIES[activity]

        # An activity type we have never seen. Named in the report rather than
        # swallowed: a broker adding a type is exactly how an import starts
        # silently losing rows.
        if mapped.nil?
          record(tally[:skipped], "#{activity} row", decimal(row["net_cash_amount"]) || decimal(row["quantity"]))
          return nil
        end

        amount = decimal(row["net_cash_amount"])
        # DROPPED, not imported at zero and not failing the portfolio: the
        # cash_transactions_amount_sign CHECK forbids a zero amount, so a zero row
        # would abort the whole savepoint. A no-op row is worth a warning, not a
        # lost portfolio.
        if amount.nil? || amount.zero?
          tally[:dropped][CASH_LABELS.fetch(activity, activity)] += 1
          return nil
        end

        amount = amount.round(FEES_SCALE)
        # Rounding a sub-half-cent movement to zero would hit the same CHECK.
        if amount.zero?
          tally[:dropped][CASH_LABELS.fetch(activity, activity)] += 1
          return nil
        end

        record(tally[:cash], CASH_LABELS.fetch(activity, activity), amount)

        CashSpec.new(
          kind: mapped == BY_SIGN ? (amount.negative? ? "withdrawal" : "deposit") : mapped,
          # SIGNED and verbatim. Never .abs: the sign is the difference between a
          # dividend and its reversal, and between a tax withholding and a refund.
          amount: amount,
          # transaction_date, not settlement_date — the same reasoning as trades:
          # settlement can trail by days and would shift the movement off the day
          # it actually happened, and cash is bucketed onto trading days by date.
          occurred_on: date(row["transaction_date"]),
          notes: nil
        )
      end

      # A SecurityTransfer is synthesized as a BUY (or SELL) priced at
      # net_cash_amount / quantity, so the cash ledger will debit (or credit) it
      # like any other trade — but no cash ever crossed the account boundary: the
      # SHARES did. Left alone, an incoming transfer reads as if the user spent
      # money they never spent (about -$51,000 in the owner's real file).
      #
      # So each synthesized transfer gets an OFFSETTING cash movement, same date,
      # same dollars: a deposit for a transfer in, a withdrawal for a transfer out.
      # Net cash effect exactly zero, while net_deposits correctly rises by the
      # transfer's value — because those shares did come from outside. The parser's
      # own note already licenses this reading: "economically identical to
      # depositing that cash and buying at that price".
      #
      # The amount is reconstructed from the SPEC (shares x price), not read back
      # off net_cash_amount, so it equals what Portfolios::TradeCash will charge to
      # the cent. The synthesized price is rounded to 6 dp, so the raw ledger
      # amount can differ from the trade's cash effect by a fraction of a cent —
      # and a cash balance that drifts by pennies per transfer defeats the entire
      # purpose of the feature.
      def transfer_offset_for(tx)
        amount = MoneyMath.round_to_cents(tx.shares * tx.price)
        # Guarded because amount <> 0 is a CHECK. A transfer this small also has a
        # trade cash effect of 0.00, so skipping it still nets to zero.
        return nil if amount.zero?

        out = tx.side == "sell"

        CashSpec.new(
          kind: out ? "withdrawal" : "deposit",
          amount: out ? -amount : amount,
          occurred_on: tx.executed_on,
          notes: "Offsets the synthesized #{out ? 'sell' : 'buy'} for a broker transfer " \
                 "#{out ? 'out of' : 'into'} the account: the shares moved, but no cash crossed the " \
                 "account boundary, so the trade's cash effect is cancelled here."
        )
      end

      # net_cash_amount is the signed cash effect; the report shows the MAGNITUDE
      # because "62 dividend payments totalling 431.28" is what a human reads. The
      # signed value is what gets stored — only this display total is absolute.
      def record(bucket, label, amount)
        entry = bucket[label]
        entry[:count] += 1
        entry[:total] += amount.abs if amount
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

      # WORDING IS TENSE-NEUTRAL throughout, like Import's. The same strings are
      # shown for a dry run, where nothing has been written yet, and an existing
      # test greps every dry-run warning for a claim that the write already
      # happened. "are recorded" / "is dropped", never "were imported".
      def ledger_warnings(tally)
        notes = []
        notes << ingested_note(tally[:cash]) if tally[:cash].any?
        notes << dropped_note(tally[:dropped]) if tally[:dropped].any?
        notes << skipped_note(tally[:skipped]) if tally[:skipped].any?
        notes
      end

      # A POSITIVE statement of what the cash ledger receives. The old version of
      # this told the user their cash was skipped and that a dividend-funded buy
      # understated return; both became false the moment there was a cash ledger,
      # and a stale warning is worse than none — it sends the user editing
      # transaction kinds to fix a problem that no longer exists.
      def ingested_note(cash)
        summary = summarize(cash)
        total = cash.values.sum { |data| data[:count] }

        "#{summary.to_sentence} #{total == 1 ? 'is' : 'are'} recorded in the portfolio’s cash ledger, so its " \
        "total value includes its cash balance and contributed capital comes from the deposit rows rather " \
        "than being inferred from what was bought. A purchase funded by a dividend or by interest is " \
        "therefore not counted as a new contribution."
      end

      def dropped_note(dropped)
        summary = dropped.sort.map { |label, count| "#{count} #{label.pluralize(count)}" }
        total = dropped.values.sum

        "#{summary.to_sentence} #{total == 1 ? 'carries' : 'carry'} no amount, so " \
        "#{total == 1 ? 'it is' : 'they are'} dropped — a cash movement of zero has no effect on the balance."
      end

      def skipped_note(skipped)
        summary = summarize(skipped)
        total = skipped.values.sum { |data| data[:count] }

        "#{summary.to_sentence} #{total == 1 ? 'is' : 'are'} not a recognized activity type, so " \
        "#{total == 1 ? 'it is' : 'they are'} skipped. Nothing in the file is silently ignored: if this " \
        "names something that should have been imported, the export format has changed."
      end

      # Capped at EXAMPLE_LIMIT categories for the same reason the venue-suffix
      # list is: an unreadable paragraph buries the sentence that matters.
      def summarize(bucket)
        sorted = bucket.sort_by { |label, _| label }
        shown = sorted.first(EXAMPLE_LIMIT).map do |label, data|
          amount = data[:total].positive? ? " totalling #{money(data[:total])}" : ""
          "#{data[:count]} #{label.pluralize(data[:count])}#{amount}"
        end
        rest = sorted.size - EXAMPLE_LIMIT
        rest.positive? ? shown + [ "#{rest} more #{'category'.pluralize(rest)}" ] : shown
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
