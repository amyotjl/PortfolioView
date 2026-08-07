module Portfolios
  module Transfer
    # Builds the native export envelope for one user's portfolios (backlog #064).
    #
    # WHAT IS AND ISN'T IN THE FILE
    #
    # In: portfolio name, benchmark by NAME, every transaction, every recurring
    # rule, and the full identity of every instrument referenced. Nothing is
    # keyed by primary key — see Portfolios::Transfer's header for why.
    #
    # Out, deliberately:
    #   * ids, series_version, created_at/updated_at — target-database concerns.
    #   * daily_prices / split_events / dividend_events — provider-owned and
    #     re-fetchable; a full history would dwarf the user's own data and go
    #     stale the day after export. The importer relies on the same
    #     first-reference backfill a manually typed transaction triggers.
    #   * paused_reason / consecutive_skips — runtime state of the materializer,
    #     not user intent. A re-imported rule starts clean.
    #
    # Money and share figures are STRINGS (`to_s("F")`), matching the API's
    # BigDecimal-end-to-end contract; JSON floats would silently round a
    # 8-decimal share count.
    class Export
      def self.call(...) = new(...).call

      # portfolio_ids: optional subset filter. Ids the user doesn't own are
      # simply absent from the result (the scope is user-owned), so a probe
      # can't confirm existence.
      def initialize(user:, portfolio_ids: nil, exported_at: Time.current)
        @user = user
        @portfolio_ids = portfolio_ids.presence
        @exported_at = exported_at
      end

      def call
        portfolios = load_portfolios

        {
          format: NATIVE_FORMAT,
          # Contents-dependent: 2 only when some portfolio actually carries cash.
          # See Portfolios::Transfer.native_version for why this moves at all.
          version: Transfer.native_version(cash: portfolios.any? { |p| p.cash_transactions.any? }),
          exported_at: @exported_at.utc.iso8601,
          instruments: instrument_specs(portfolios),
          portfolios: portfolios.map { |portfolio| portfolio_payload(portfolio) }
        }
      end

      # Stable, sortable, collision-resistant download name.
      def filename
        "portfolioview-portfolios-#{@exported_at.utc.strftime('%Y%m%d-%H%M%S')}.json"
      end

      private

      def load_portfolios
        scope = @user.portfolios
        scope = scope.where(id: @portfolio_ids) if @portfolio_ids
        # includes() is load-bearing: without it each transaction/rule would
        # re-query its instrument to serialize the symbol.
        scope.includes(:benchmark, :cash_transactions,
                       { transactions: :instrument }, { recurring_transactions: :instrument })
             .order(:created_at, :id)
             .to_a
      end

      # One entry per distinct instrument across every exported portfolio,
      # symbol-ordered so two exports of the same data are byte-identical.
      def instrument_specs(portfolios)
        instruments = portfolios.flat_map do |portfolio|
          portfolio.transactions.map(&:instrument) + portfolio.recurring_transactions.map(&:instrument)
        end

        instruments.uniq(&:id).sort_by(&:symbol).map do |instrument|
          {
            symbol: instrument.symbol,
            name: instrument.name,
            instrument_type: instrument.instrument_type,
            currency: instrument.currency,
            sector: instrument.sector,
            industry: instrument.industry
          }
        end
      end

      def portfolio_payload(portfolio)
        rules = portfolio.recurring_transactions.sort_by(&:id)
        # File-local keys ("r1", "r2", ...) let a transaction point at the rule
        # that materialized it without either having an id in the target DB.
        keys_by_rule_id = rules.each_with_index.to_h { |rule, index| [ rule.id, "r#{index + 1}" ] }

        payload = {
          name: portfolio.name,
          benchmark: portfolio.benchmark&.name,
          transactions: portfolio.transactions
                                 .sort_by { |tx| [ tx.executed_on, tx.id ] }
                                 .map { |tx| transaction_payload(tx, keys_by_rule_id) },
          recurring_transactions: rules.map { |rule| recurring_payload(rule, keys_by_rule_id) }
        }

        # OMITTED, not written as [], when the portfolio has no cash (issue #80).
        # That is what keeps a no-cash export byte-identical to a pre-#80 one and
        # lets the envelope stay at version 1 — see
        # Portfolios::Transfer.native_version, which is the other half of this.
        cash = portfolio.cash_transactions.sort_by { |row| [ row.occurred_on, row.id ] }
        payload[:cash_transactions] = cash.map { |row| cash_payload(row) } if cash.any?

        payload
      end

      # `amount` goes out SIGNED and verbatim. Nothing here may take a magnitude:
      # a negative dividend_cash (a broker reversal) and a positive tax (a refund)
      # are legitimate rows whose sign IS the information.
      def cash_payload(row)
        {
          kind: row.kind,
          amount: row.amount.to_s("F"),
          occurred_on: row.occurred_on.iso8601,
          notes: row.notes
        }
      end

      def transaction_payload(transaction, keys_by_rule_id)
        {
          symbol: transaction.instrument.symbol,
          side: transaction.side,
          kind: transaction.kind,
          shares: transaction.shares.to_s("F"),
          price: transaction.price.to_s("F"),
          fees: transaction.fees.to_s("F"),
          executed_on: transaction.executed_on.iso8601,
          notes: transaction.notes,
          recurring_key: keys_by_rule_id[transaction.recurring_transaction_id],
          scheduled_for: transaction.scheduled_for&.iso8601
        }
      end

      def recurring_payload(rule, keys_by_rule_id)
        {
          key: keys_by_rule_id.fetch(rule.id),
          symbol: rule.instrument.symbol,
          side: rule.side,
          amount_type: rule.amount_type,
          dollar_amount: rule.dollar_amount&.to_s("F"),
          share_amount: rule.share_amount&.to_s("F"),
          frequency: rule.frequency,
          anchor_on: rule.anchor_on.iso8601,
          next_run_on: rule.next_run_on.iso8601,
          end_on: rule.end_on&.iso8601,
          active: rule.active
        }
      end
    end
  end
end
