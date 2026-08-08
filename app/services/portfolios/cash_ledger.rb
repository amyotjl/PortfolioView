module Portfolios
  # The liquid-cash balance as a TIME SERIES (issue #80), not a scalar:
  # /summary's current_value and the chart's last point must not be able to
  # contradict each other, so the balance has to be known per day.
  #
  #   balance(D) = Sum(cash movements effective <= D) - Sum(TradeCash.for(tx) effective <= D)
  #
  # Balances are END-OF-DAY: the day's cash movements and trades are applied,
  # then the running balance is snapshotted. frontend/src/charts/contributions.ts
  # depends on that reading — this is load-bearing, not an implementation detail.
  #
  # Bucketing matches Valuation#build_flows exactly: a movement takes effect on
  # the first trading day ON OR AFTER its date (a weekend deposit lands Monday),
  # found by `days.bsearch`.
  #
  # SPLITS DO NOT TOUCH CASH. A split moves share counts, not money, so no split
  # arm exists here and none should be added.
  #
  # EVERY TRADE MOVES CASH, REGARDLESS OF `kind` — dividend_reinvestment
  # INCLUDED. This is NOT the same rule as the DRIP exclusion in
  # Valuation#build_flows and Benchmarks::Simulation, and conflating the two is
  # the trap: those say a DRIP is not an external CONTRIBUTION (it must not
  # inflate net_deposits or buy the shadow ETF free shares), which stays true.
  # This says a DRIP still SPENT money out of the cash account, which is also
  # true — the dividend arrives as a `dividend_cash` credit (the importer records
  # all six kinds) and the reinvestment spends it, so the pair nets to zero and
  # the gain lands in return where it belongs.
  #
  # Excluding the debit here looks harmless in isolation and is not: with the
  # credit recorded and the debit skipped, cash is permanently inflated by the
  # dividend and total value DOUBLE-COUNTS it — once as the new shares, once as
  # the cash that bought them. Two tests pin this; read them before "fixing" it.
  #
  # Query budget: `call` is PURE (zero queries). It takes `days:` and
  # `transactions:` from Valuation, which has already materialized both, and the
  # cash rows from `rows_for` — exactly ONE query added to a valuation. Do not
  # re-derive the trading calendar here: `SELECT DISTINCT date FROM daily_prices`
  # measures 59 ms and a full sequential scan of the largest table in the schema.
  class CashLedger
    ZERO = BigDecimal(0)

    # One cash movement, flattened out of the database so the sweep never touches
    # ActiveRecord. `amount` is SIGNED as stored (deposit > 0, withdrawal < 0).
    Row = Data.define(:kind, :amount, :occurred_on) do
      def external? = CashTransaction::EXTERNAL_KINDS.include?(kind)
    end

    # tracked            false => every other member is empty/zero and every
    #                    caller must behave exactly as it did before #80
    # balances           { Date => BigDecimal }, one key per swept day, END-OF-DAY
    # closing_balance    the last swept day's balance
    # external_by_date   { Date => [Row] } — deposits/withdrawals ONLY, by
    #                    effective trading day (the flow items /candles lists)
    # net_external_total signed sum of those rows == Sum(flows[].net) == net_deposits
    # first_negative_on  first day the CENT-ROUNDED balance is < 0 (nil if never).
    #
    #                    CONTRACT SURFACE WITH NO CURRENT READER — DO NOT DELETE
    #                    AS DEAD CODE. It reaches the wire three times
    #                    (summary.cash_negative_since, candles meta, and the
    #                    cash-CRUD balance meta), but the SPA derives negativity
    #                    from the balance string instead, deliberately: the figure
    #                    and the sentence quoting it then come from one value and
    #                    cannot disagree. That leaves this the ONLY place the
    #                    "negative since WHEN" information exists anywhere in the
    #                    system — the balance string cannot answer it, and no
    #                    other field carries the date. Removing it would silently
    #                    foreclose the follow-up that shows it (issue #80's gate
    #                    filed one). `cash_negative` is likewise unread but is
    #                    recomputable from the balance; this is not.
    # min_balance        running minimum: a portfolio can end positive having
    #                    been negative, and the warning is about the dip
    # unbucketed         a cash row the trading calendar cannot place yet, which
    #                    ORs into meta[:partial]
    Result = Data.define(
      :tracked, :balances, :closing_balance, :external_by_date,
      :net_external_total, :first_negative_on, :min_balance, :unbucketed
    )

    # The single "this portfolio does not track cash" value. Valuation::Result
    # defaults its `cash` member to this so positional construction and every
    # pre-#80 test keep working unchanged.
    UNTRACKED = Result.new(
      tracked: false, balances: {}.freeze, closing_balance: ZERO,
      external_by_date: {}.freeze, net_external_total: ZERO,
      first_negative_on: nil, min_balance: ZERO, unbucketed: false
    )

    class << self
      def call(...) = new(...).call

      # THE one query. Ordered by occurred_on so `rows.first` is the earliest
      # movement — Valuation needs that for its cash-aware inception before it
      # can know which days to sweep.
      def rows_for(portfolio)
        portfolio.cash_transactions
                 .order(:occurred_on, :id)
                 .pluck(:kind, :amount, :occurred_on)
                 .map { |kind, amount, occurred_on| Row.new(kind: kind, amount: MoneyMath.decimal(amount), occurred_on: occurred_on) }
      end

      # Standalone entry point for callers that have no valuation in hand (the
      # cash CRUD endpoint's balance meta): loads the rows, the trades and the
      # calendar itself — 3 queries, no price sweep — and produces a ledger
      # IDENTICAL to the one Valuation computes, so a create/update toast can
      # never contradict the /summary tile the user is looking at.
      def for_portfolio(portfolio, to: nil)
        rows = rows_for(portfolio)
        to ||= Trading::Calendar.last_day
        txs = to ? portfolio.transactions.where(executed_on: ..to).order(:executed_on, :id).to_a : []
        inception = [ txs.first&.executed_on, rows.first&.occurred_on ].compact.min
        days = inception && to ? Trading::Calendar.days_between(inception, to) : []

        call(rows: rows, days: days, transactions: txs, to: to)
      end
    end

    # rows          Row list (already loaded — see rows_for)
    # days          the swept trading days, ascending (Valuation's holdings.keys)
    # transactions  the same transaction objects Valuation swept
    # to            the window end; a movement dated after it belongs to a later
    #               window and is neither counted nor reported as unbucketed
    def initialize(rows:, days:, transactions:, to:)
      @rows = rows
      @days = days
      @transactions = transactions
      @to = to
    end

    def call
      return UNTRACKED if rows.empty?

      in_window = to.nil? ? [] : rows.select { |row| row.occurred_on <= to }
      cash_by_date, unbucketed = bucket_cash(in_window)

      sweep(cash_by_date, bucket_trades, unbucketed)
    end

    private

    attr_reader :rows, :days, :transactions, :to

    # { effective Date => [Row] } plus the unbucketed flag.
    def bucket_cash(in_window)
      by_date = {}
      unbucketed = false

      in_window.each do |row|
        effective = effective_day(row.occurred_on)
        if effective.nil?
          # The price cache does not reach this movement yet, so it is in NO
          # day's balance. build_flows tolerates that for a trade (`next if
          # effective.nil?` — the position is what matters there), but for cash
          # it silently LOSES MONEY, so it is reported instead and ORed into
          # meta[:partial]: the payload is never cached and never presented as
          # complete. It resolves itself once the calendar catches up.
          unbucketed = true
          next
        end

        (by_date[effective] ||= []) << row
      end

      [ by_date, unbucketed ]
    end

    # { effective Date => BigDecimal } — the cent-rounded cash each day's trades
    # moved, summed per day AFTER per-transaction rounding.
    #
    # EVERY trade, every `kind`. There is deliberately no dividend_reinvestment
    # arm: a DRIP spent cash, and its funding `dividend_cash` credit is a row in
    # the same ledger. (The DRIP exclusions in Valuation#build_flows and
    # Benchmarks::Simulation are a DIFFERENT rule — "not an external
    # contribution" — and stay exactly where they are.)
    def bucket_trades
      by_date = {}

      transactions.each do |tx|
        effective = effective_day(tx.executed_on)
        next if effective.nil?

        by_date[effective] = (by_date[effective] || ZERO) + TradeCash.for(tx)
      end

      by_date
    end

    # First trading day on or after `date` — the same rule (and the same
    # `days.bsearch`) Valuation#build_flows uses to bucket a flow.
    def effective_day(date)
      days.bsearch { |day| day >= date }
    end

    def sweep(cash_by_date, trade_by_date, unbucketed)
      balance = ZERO
      balances = {}
      external_by_date = {}
      net_external = ZERO
      min_balance = nil
      first_negative_on = nil

      days.each do |date|
        cash_by_date.fetch(date, []).each do |row|
          balance += row.amount
          next unless row.external?

          (external_by_date[date] ||= []) << row
          net_external += row.amount
        end
        balance -= trade_by_date.fetch(date, ZERO)

        balances[date] = balance

        # The negative flag is computed on the CENT-ROUNDED balance so a
        # -$0.000004 residual can never raise a warning at the user.
        rounded = MoneyMath.round_to_cents(balance)
        min_balance = rounded if min_balance.nil? || rounded < min_balance
        first_negative_on ||= date if rounded.negative?
      end

      Result.new(
        tracked: true,
        balances: balances.freeze,
        closing_balance: balances.values.last || ZERO,
        external_by_date: external_by_date.freeze,
        net_external_total: net_external,
        first_negative_on: first_negative_on,
        min_balance: min_balance || ZERO,
        unbucketed: unbucketed
      )
    end
  end
end
