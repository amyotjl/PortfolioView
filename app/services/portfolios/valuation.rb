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
  # Passing `transactions:` (objects responding to instrument_id / side / kind
  # / shares / price / fees / executed_on) replaces the portfolio's stored
  # transactions — Benchmarks::Simulation feeds its synthetic trades through
  # this exact machinery. All arithmetic is BigDecimal (MoneyMath).
  class Valuation
    APPROXIMATION = "component_extrema".freeze

    Candle        = Data.define(:date, :open, :high, :low, :close)
    DrawdownPoint = Data.define(:date, :value)
    FlowItem      = Data.define(:instrument_id, :symbol, :side, :amount)
    Flow          = Data.define(:date, :net, :items)
    Result        = Data.define(:candles, :drawdown, :flows, :meta)

    def self.call(...) = new(...).call

    def initialize(portfolio:, from:, to:, transactions: nil)
      @portfolio = portfolio
      @from = from
      @to = to
      @transactions = transactions
    end

    def call
      txs = load_transactions
      return empty_result if txs.empty?

      inception  = txs.map(&:executed_on).min
      sweep_from = [ inception, from ].min

      holdings = Holdings::Calculator.call(portfolio: portfolio, from: sweep_from, to: to,
                                           transactions: txs).holdings
      days = holdings.keys
      instrument_ids = txs.map(&:instrument_id).uniq

      candles, drawdown, filled_dates, partial =
        sweep(days, holdings, prices_by_date(instrument_ids, sweep_from), seed_closes(instrument_ids, sweep_from), inception)
      flows = build_flows(txs, days)

      Result.new(
        candles: candles.freeze,
        drawdown: drawdown.freeze,
        flows: flows.freeze,
        meta: meta(filled_dates: filled_dates, partial: partial)
      )
    end

    private

    attr_reader :portfolio, :from, :to, :transactions

    def load_transactions
      transactions ||
        portfolio.transactions.where(executed_on: ..to).order(:executed_on, :id).to_a
    end

    # { date => [ [instrument_id, open, high, low, close], ... ] }
    def prices_by_date(instrument_ids, sweep_from)
      DailyPrice.where(instrument_id: instrument_ids, date: sweep_from..to)
                .pluck(:instrument_id, :date, :open, :high, :low, :close)
                .group_by { |_iid, date, *| date }
    end

    # Latest close strictly before the sweep for each instrument, so a gap on
    # the very first swept day still has something to forward-fill from.
    def seed_closes(instrument_ids, sweep_from)
      DailyPrice.where(instrument_id: instrument_ids)
                .where(date: ...sweep_from)
                .select("DISTINCT ON (instrument_id) instrument_id, close")
                .order(:instrument_id, date: :desc)
                .map { |row| [ row.instrument_id, row.close ] }
                .to_h
    end

    def sweep(days, holdings, prices, last_close, inception)
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

        peak = close if close > peak

        next if date < inception || date < from

        candles << Candle.new(date: date, open: open, high: high, low: low, close: close)
        filled_dates << date if day_filled
        drawdown << DrawdownPoint.new(date: date, value: drawdown_value(close, peak))
      end

      [ candles, drawdown, filled_dates, partial ]
    end

    def drawdown_value(value, peak)
      return BigDecimal(0) unless peak.positive?
      ((value - peak) / peak).round(8)
    end

    def build_flows(txs, days)
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
          amount: external_amount(tx)
        )
      end

      items_by_date.keys.sort.map do |date|
        items = items_by_date[date]
        Flow.new(date: date, net: items.sum(BigDecimal(0), &:amount), items: items.freeze)
      end
    end

    # Signed external cash: a buy pushes cost + fees INTO the portfolio; a
    # sell withdraws proceeds net of fees.
    def external_amount(tx)
      shares = MoneyMath.decimal(tx.shares)
      price  = MoneyMath.decimal(tx.price)
      fees   = MoneyMath.decimal(tx.fees)
      tx.side == "sell" ? -(shares * price - fees) : shares * price + fees
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
