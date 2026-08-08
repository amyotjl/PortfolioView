module Benchmarks
  # Cash-flow-matched benchmark (docs/PLAN.md § Core domain logic): every real
  # external transaction becomes a synthetic SAME-DOLLAR trade of the
  # benchmark ETF, and the synthetic trade list is fed through the exact same
  # Holdings::Calculator / Portfolios::Valuation machinery as the portfolio —
  # so benchmark splits (e.g. SPY) are handled by the shared CSF logic.
  #
  # Dollar matching: buys convert cost + fees (the full external cash that
  # left the user's pocket), sells convert proceeds - fees. Fills happen at
  # the close of the first benchmark trading day ON OR AFTER executed_on —
  # "the next close available to the trade": a trading-day trade fills at that
  # same day's close (anything later would systematically lag the portfolio's
  # own effect date), a weekend trade fills at Monday's close. Synthetic
  # shares are dollars / close rounded to 8 dp.
  #
  # kind: dividend_reinvestment is EXCLUDED — a DRIP is internal compounding;
  # matching it would hand the shadow portfolio free money (the price-return
  # benchmark deliberately models none of its own dividends either).
  #
  # WHICH MOVEMENTS ARE MATCHED depends on the portfolio's basis (issue #80).
  # For a CASH-TRACKED portfolio the shadow ETF matches DEPOSITS AND WITHDRAWALS,
  # not trades, because summary.rb computes
  #
  #   benchmark_return_pct = pct(sim.values.last.value - net_deposits, net_deposits)
  #
  # and net_deposits is the deposit ledger there. Keep matching trades while the
  # denominator switches and that expression subtracts a deposit-basis figure
  # from a trade-basis simulation: off by (Σ trade cost − Σ deposits), silently,
  # with no flag and no null. docs/PLAN.md asked for the deposit version from the
  # start ("simulate the user's exact deposits, on the same dates, into an index
  # ETF"); trade matching was only ever the proxy available before there were
  # deposits to match. The trade branch is UNCHANGED for untracked portfolios.
  #
  # Only CashTransaction::EXTERNAL_KINDS are matched — the DRIP rule generalized:
  # interest, dividend_cash, tax and fee move the balance but are money the
  # broker moved INSIDE the account, so matching them would hand the shadow
  # portfolio free money the benchmark side never models.
  #
  # The shadow ETF needs no cash account of its own: under deposit matching it is
  # fully invested by construction, which is what a benchmark IS. That also means
  # it now correctly PENALIZES idle cash — expect vs_benchmark_edge_pct to move
  # down on cash-heavy accounts that adopt cash tracking.
  #
  # Guard rails:
  # - an over-withdrawal clamps the shadow position at zero and sets
  #   meta[:benchmark_clamped]
  # - benchmark history shorter than the portfolio clamps early fills to the
  #   first available benchmark close and sets meta[:sim_start_clamped]
  # - a trade with no benchmark close on/after it yet is dropped and sets
  #   meta[:partial] (the value line cannot extend there anyway)
  #
  # v1 is explicitly PRICE-RETURN: meta[:return_basis] = "price_return"
  # (v1.1 upgrades to total-return by reinvesting dividend_events).
  class Simulation
    RETURN_BASIS = "price_return".freeze

    SyntheticTransaction = Data.define(:instrument_id, :side, :kind, :shares, :price, :fees, :executed_on)
    Point  = Data.define(:date, :value)
    Result = Data.define(:instrument_id, :symbol, :values, :meta)

    # One external movement to match, normalized so the fill sweep is identical
    # for a trade and for a cash movement: `dollars` is the magnitude in the
    # direction's own sign, `side` buys or sells the shadow ETF.
    Movement = Data.define(:side, :executed_on, :dollars)
    private_constant :Movement

    def self.call(...) = new(...).call

    def initialize(portfolio:, from:, to:, benchmark: nil)
      @portfolio = portfolio
      @from = from
      @to = to
      @benchmark = benchmark || portfolio.benchmark
      raise ArgumentError, "portfolio has no benchmark to simulate" if @benchmark.nil?
    end

    def call
      real = external_movements
      dates, closes = benchmark_closes

      synthetic, flags = build_synthetic_trades(real, dates, closes)
      # include_cash: false is redundant belt-and-braces (an injected transaction
      # list already defaults it off) — the shadow ETF must never inherit the
      # user's cash, and that must be impossible to break by accident.
      valuation = Portfolios::Valuation.call(portfolio: portfolio, from: from, to: to,
                                             transactions: synthetic, include_cash: false)

      Result.new(
        instrument_id: instrument.id,
        symbol: instrument.symbol,
        values: valuation.candles.map { |c| Point.new(date: c.date, value: c.close) }.freeze,
        meta: {
          return_basis: RETURN_BASIS,
          benchmark_clamped: flags[:clamped],
          sim_start_clamped: flags[:start_clamped],
          partial: flags[:dropped] || valuation.meta[:partial],
          filled_dates: valuation.meta[:filled_dates]
        }.freeze
      )
    end

    private

    attr_reader :portfolio, :from, :to, :benchmark

    def instrument = benchmark.instrument

    # The movements the shadow ETF matches, ordered by date (the fill sweep
    # relies on non-decreasing fill dates to apply each split exactly once).
    #
    # `tracked` is derived from the cash rows loaded HERE rather than from a
    # second Portfolio#cash_tracked? call: that predicate's `SELECT 1 ... LIMIT 1`
    # early-exit estimate makes Postgres prefer a Seq Scan, which for an
    # UNTRACKED portfolio scans the whole table to prove absence.
    def external_movements
      cash_rows = portfolio.cash_transactions.order(:occurred_on, :id)
                           .pluck(:kind, :amount, :occurred_on)
      return cash_movements(cash_rows) if cash_rows.any?

      trade_movements
    end

    # Deposits and withdrawals only, in window. A withdrawal is stored negative,
    # so its magnitude sells the shadow position.
    def cash_movements(cash_rows)
      cash_rows.filter_map do |kind, amount, occurred_on|
        next unless CashTransaction::EXTERNAL_KINDS.include?(kind)
        next if occurred_on > to

        amount = MoneyMath.decimal(amount)
        Movement.new(side: amount.negative? ? "sell" : "buy",
                     executed_on: occurred_on, dollars: amount.abs)
      end
    end

    def trade_movements
      portfolio.transactions
               .where(kind: "normal")
               .where(executed_on: ..to)
               .order(:executed_on, :id)
               .map { |tx| Movement.new(side: tx.side, executed_on: tx.executed_on, dollars: Portfolios::TradeCash.dollars(tx)) }
    end

    # [sorted dates array, {date => close}]
    def benchmark_closes
      pairs = instrument.daily_prices.where(date: ..to).order(:date).pluck(:date, :close)
      [ pairs.map(&:first), pairs.to_h ]
    end

    def benchmark_splits
      instrument.split_events.order(:ex_date).pluck(:ex_date, :ratio)
    end

    def build_synthetic_trades(real, dates, closes)
      flags = { clamped: false, start_clamped: false, dropped: false }
      return [ [], flags ] if real.empty?

      splits = benchmark_splits
      split_index = 0
      position = BigDecimal(0)
      synthetic = []

      # real is ordered by executed_on, so fill dates are non-decreasing and
      # one forward sweep applies each split exactly once.
      real.each do |movement|
        fill_date = dates.bsearch { |d| d >= movement.executed_on }
        if fill_date.nil?
          flags[:dropped] = true
          next
        end
        flags[:start_clamped] = true if movement.executed_on < dates.first

        # Splits apply at the START of their ex-date, before same-day fills.
        while split_index < splits.size && splits[split_index][0] <= fill_date
          position *= splits[split_index][1]
          split_index += 1
        end

        dollars = movement.dollars
        next unless dollars.positive?

        close  = closes.fetch(fill_date)
        shares = (dollars / close).round(8)

        if movement.side == "sell"
          if shares > position
            shares = position
            flags[:clamped] = true
          end
          next unless shares.positive?
          position -= shares
        else
          position += shares
        end

        synthetic << SyntheticTransaction.new(
          instrument_id: instrument.id, side: movement.side, kind: "normal",
          shares: shares, price: close, fees: BigDecimal(0), executed_on: fill_date
        )
      end

      [ synthetic, flags ]
    end
  end
end
