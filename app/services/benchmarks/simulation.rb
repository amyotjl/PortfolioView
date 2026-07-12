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

    def self.call(...) = new(...).call

    def initialize(portfolio:, from:, to:, benchmark: nil)
      @portfolio = portfolio
      @from = from
      @to = to
      @benchmark = benchmark || portfolio.benchmark
      raise ArgumentError, "portfolio has no benchmark to simulate" if @benchmark.nil?
    end

    def call
      real = external_transactions
      dates, closes = benchmark_closes

      synthetic, flags = build_synthetic_trades(real, dates, closes)
      valuation = Portfolios::Valuation.call(portfolio: portfolio, from: from, to: to,
                                             transactions: synthetic)

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

    def external_transactions
      portfolio.transactions
               .where(kind: "normal")
               .where(executed_on: ..to)
               .order(:executed_on, :id)
               .to_a
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
      real.each do |tx|
        fill_date = dates.bsearch { |d| d >= tx.executed_on }
        if fill_date.nil?
          flags[:dropped] = true
          next
        end
        flags[:start_clamped] = true if tx.executed_on < dates.first

        # Splits apply at the START of their ex-date, before same-day fills.
        while split_index < splits.size && splits[split_index][0] <= fill_date
          position *= splits[split_index][1]
          split_index += 1
        end

        dollars = external_dollars(tx)
        next unless dollars.positive?

        close  = closes.fetch(fill_date)
        shares = (dollars / close).round(8)

        if tx.side == "sell"
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
          instrument_id: instrument.id, side: tx.side, kind: "normal",
          shares: shares, price: close, fees: BigDecimal(0), executed_on: fill_date
        )
      end

      [ synthetic, flags ]
    end

    # The external cash the real trade moved: buys cost + fees, sells
    # proceeds - fees — the same convention as Portfolios::Valuation flows.
    def external_dollars(tx)
      shares = MoneyMath.decimal(tx.shares)
      price  = MoneyMath.decimal(tx.price)
      fees   = MoneyMath.decimal(tx.fees)
      tx.side == "sell" ? shares * price - fees : shares * price + fees
    end
  end
end
