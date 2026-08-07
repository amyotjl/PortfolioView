module Portfolios
  # Portfolio valuation series (docs/PLAN.md § Core domain logic):
  #
  #   portfolio O/H/L/C per trading day = Σ shares(i, D) × component O/H/L/C
  #
  # Portfolio HIGH/LOW are documented BOUNDS — component extremes don't
  # co-occur intraday, which is the correct honest statement for EOD data —
  # flagged on every response via meta[:approximation] = "component_extrema".
  #
  # A missing instrument-day forward-fills that instrument's last known close
  # into ALL FOUR legs (a flat contribution) and records the portfolio date in
  # meta[:filled_dates]. A held instrument-day with no obtainable price at all
  # (no earlier close either) contributes zero and sets meta[:partial].
  #
  # Drawdown is computed from INCEPTION-to-date closes against the all-time
  # peak — never the requested window's peak — so the service always sweeps
  # from the first transaction even when `from` is later, and only emits the
  # window's points.
  #
  # Flows are per-date net EXTERNAL cash: buys contribute cost + fees, sells
  # withdraw proceeds - fees, each bucketed to its effective trading day (the
  # first trading day on or after executed_on — weekend trades take effect the
  # next trading day). kind: dividend_reinvestment transactions are EXCLUDED —
  # a DRIP is internal compounding, not external cash (and the benchmark side
  # must not be handed matching free money).
  #
  # LIQUID CASH (issue #80) is governed by ONE predicate: a portfolio tracks cash
  # iff it has at least one cash_transactions row. Tracked =>
  #
  #   - candle O/H/L/C stay HOLDINGS-ONLY (the candlestick grammar says "this is
  #     a market move", so a deposit drawn as a tall green candle is a lie about
  #     performance, and cash has no O/H/L to dilute the wick with). Cash is
  #     emitted as its own series, Result#cash;
  #   - drawdown IS computed on the cash-inclusive close, internally, before
  #     emitting — otherwise every sell reads as a drawdown with nothing to
  #     offset it;
  #   - `flows` become the CASH movements (deposits/withdrawals only) instead of
  #     the trades, EXCLUSIVELY: under a full cash account a trade is an internal
  #     transfer that moves no total value.
  #
  # Untracked => every path here is exactly what it was before #80.
  #
  # `include_cash:` defaults to `transactions.nil?` so the dangerous case is off
  # by default: an injected transaction list is a SYNTHETIC portfolio
  # (Benchmarks::Simulation's shadow ETF), which must never inherit the real
  # portfolio's cash.
  #
  # Passing `transactions:` (objects responding to instrument_id / side / kind
  # / shares / price / fees / executed_on) replaces the portfolio's stored
  # transactions — Benchmarks::Simulation feeds its synthetic trades through
  # this exact machinery. All arithmetic is BigDecimal (MoneyMath).
  class Valuation
    APPROXIMATION = "component_extrema".freeze

    Candle        = Data.define(:date, :open, :high, :low, :close)
    DrawdownPoint = Data.define(:date, :value)
    # `side` carries "buy"/"sell" for a trade item and the CASH KIND
    # ("deposit"/"withdrawal") for a cash item — it is what the serializer emits
    # as the flow item's `kind`. `instrument_id`/`symbol` are nil on a cash item.
    FlowItem      = Data.define(:instrument_id, :symbol, :side, :amount)
    Flow          = Data.define(:date, :net, :items)

    Result = Data.define(:candles, :drawdown, :flows, :meta, :cash) do
      # `cash` defaults so every pre-#80 construction site and test keeps working
      # without naming a member it never produced — the same pattern
      # Transfer::Document uses for `splits`.
      def initialize(cash: CashLedger::UNTRACKED, **rest)
        super(cash: cash, **rest)
      end
    end

    def self.call(...) = new(...).call

    def initialize(portfolio:, from:, to:, transactions: nil, include_cash: nil)
      @portfolio = portfolio
      @from = from
      @to = to
      @transactions = transactions
      # Injected transactions => synthetic portfolio => no cash, unless a caller
      # deliberately says otherwise.
      @include_cash = include_cash.nil? ? transactions.nil? : include_cash
    end

    def call
      txs = load_transactions
      cash_rows = include_cash ? CashLedger.rows_for(portfolio) : []
      # A portfolio with a deposit and no trades is real and must produce a
      # series equal to its cash balance, so the early return needs BOTH empty.
      return empty_result if txs.empty? && cash_rows.empty?

      inception  = inception_of(txs, cash_rows)
      sweep_from = [ inception, from ].min

      holdings = Holdings::Calculator.call(portfolio: portfolio, from: sweep_from, to: to,
                                           transactions: txs).holdings
      days = holdings.keys
      instrument_ids = txs.map(&:instrument_id).uniq

      cash = CashLedger.call(rows: cash_rows, days: days, transactions: txs, to: to)

      candles, drawdown, filled_dates, partial =
        sweep(days, holdings, prices_by_date(instrument_ids, sweep_from), seed_closes(instrument_ids, sweep_from),
              inception, cash)
      flows = build_flows(txs, days, cash)

      Result.new(
        candles: candles.freeze,
        drawdown: drawdown.freeze,
        flows: flows.freeze,
        cash: cash,
        meta: meta(filled_dates: filled_dates, partial: partial || cash.unbucketed)
      )
    end

    private

    attr_reader :portfolio, :from, :to, :transactions, :include_cash

    # Inception is the earlier of the first trade and the first cash movement.
    # Taking only the first trade was a live BUG: a deposit predating it was
    # dropped by build_flows' `next if effective < from` and net_deposits
    # silently understated.
    def inception_of(txs, cash_rows)
      [ txs.map(&:executed_on).min, cash_rows.first&.occurred_on ].compact.min
    end

    def load_transactions
      transactions ||
        portfolio.transactions.where(executed_on: ..to).order(:executed_on, :id).to_a
    end

    # { date => [ [instrument_id, open, high, low, close], ... ] }
    def prices_by_date(instrument_ids, sweep_from)
      return {} if instrument_ids.empty?

      DailyPrice.where(instrument_id: instrument_ids, date: sweep_from..to)
                .pluck(:instrument_id, :date, :open, :high, :low, :close)
                .group_by { |_iid, date, *| date }
    end

    # Latest close strictly before the sweep for each instrument, so a gap on
    # the very first swept day still has something to forward-fill from.
    def seed_closes(instrument_ids, sweep_from)
      return {} if instrument_ids.empty?

      DailyPrice.where(instrument_id: instrument_ids)
                .where(date: ...sweep_from)
                .select("DISTINCT ON (instrument_id) instrument_id, close")
                .order(:instrument_id, date: :desc)
                .map { |row| [ row.instrument_id, row.close ] }
                .to_h
    end

    def sweep(days, holdings, prices, last_close, inception, cash)
      zero = BigDecimal(0)
      candles, drawdown, filled_dates = [], [], []
      partial = false
      peak = zero

      days.each do |date|
        day_rows = (prices[date] || []).index_by { |iid, *| iid }

        # Track the freshest close for EVERY priced instrument — including ones
        # not currently held — so a later re-buy forward-fills from a live
        # price, not one stale since the position was closed.
        prices[date]&.each { |iid, _date, _o, _h, _l, close| last_close[iid] = close }

        open = high = low = close = zero
        day_filled = false

        holdings[date].each do |iid, shares|
          if (row = day_rows[iid])
            _iid, _date, po, ph, pl, pc = row
          elsif (fill = last_close[iid])
            po = ph = pl = pc = fill
            day_filled = true
          else
            partial = true
            next
          end
          open  += shares * po
          high  += shares * ph
          low   += shares * pl
          close += shares * pc
        end

        # Drawdown runs on the CASH-INCLUSIVE close while the candle legs stay
        # holdings-only: with a cash account a sell is value-neutral instead of
        # registering as a drawdown with nothing to offset it. (Residual, not
        # fixed: a large withdrawal still reads as a drawdown and a large deposit
        # raises the all-time peak instantly. Flow-neutralizing the peak is
        # TWR/MWR work that docs/PLAN.md defers.)
        total = cash.tracked ? close + cash.balances.fetch(date, zero) : close
        peak = total if total > peak

        next if date < inception || date < from

        candles << Candle.new(date: date, open: open, high: high, low: low, close: close)
        filled_dates << date if day_filled
        drawdown << DrawdownPoint.new(date: date, value: drawdown_value(total, peak))
      end

      [ candles, drawdown, filled_dates, partial ]
    end

    def drawdown_value(value, peak)
      return BigDecimal(0) unless peak.positive?
      ((value - peak) / peak).round(8)
    end

    # On the cash basis `flows` are the CASH movements, EXCLUSIVELY — trades are
    # absent. Summary sums flows[].net into net_deposits, so a mixed array would
    # silently corrupt it; if trade bars are ever wanted back on the cash basis
    # they belong in a separate key, never in here.
    def build_flows(txs, days, cash)
      return build_cash_flows(cash) if cash.tracked

      build_trade_flows(txs, days)
    end

    def build_cash_flows(cash)
      cash.external_by_date.keys.sort.filter_map do |date|
        next if date < from

        items = cash.external_by_date.fetch(date).map do |row|
          FlowItem.new(instrument_id: nil, symbol: nil, side: row.kind, amount: row.amount)
        end
        Flow.new(date: date, net: items.sum(BigDecimal(0), &:amount), items: items.freeze)
      end
    end

    def build_trade_flows(txs, days)
      external = txs.reject { |tx| tx.kind == "dividend_reinvestment" }
      symbols  = Instrument.where(id: external.map(&:instrument_id).uniq).pluck(:id, :symbol).to_h

      items_by_date = Hash.new { |h, k| h[k] = [] }
      external.each do |tx|
        effective = days.bsearch { |d| d >= tx.executed_on }
        next if effective.nil? || effective < from

        items_by_date[effective] << FlowItem.new(
          instrument_id: tx.instrument_id,
          symbol: symbols.fetch(tx.instrument_id, nil),
          side: tx.side,
          amount: TradeCash.for(tx)
        )
      end

      items_by_date.keys.sort.map do |date|
        items = items_by_date[date]
        Flow.new(date: date, net: items.sum(BigDecimal(0), &:amount), items: items.freeze)
      end
    end

    def meta(filled_dates:, partial:)
      { approximation: APPROXIMATION, filled_dates: filled_dates.uniq.sort.freeze, partial: partial }.freeze
    end

    def empty_result
      Result.new(candles: [].freeze, drawdown: [].freeze, flows: [].freeze,
                 meta: meta(filled_dates: [], partial: false))
    end
  end
end
