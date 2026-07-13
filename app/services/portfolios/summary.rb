module Portfolios
  # Lifetime stat-tile figures (docs/PLAN.md § API contract: "lifetime stat
  # tiles … tiles never come from a windowed candles payload"). Everything is
  # computed over the FULL history — inception (first transaction) to the last
  # trading day — via Portfolios::Valuation + Benchmarks::Simulation, never a
  # requested window.
  #
  # - current_value        last full-history close
  # - net_deposits         Σ external flows (buys +cost+fees, sells -proceeds+fees;
  #                        DRIP excluded) — the cash the user actually put in
  # - total_return         current_value − net_deposits (dollars)
  # - total_return_pct     total_return / net_deposits (nil when net_deposits ≤ 0)
  # - benchmark_return_pct the cash-flow-matched shadow ETF's return on the SAME
  #                        deposits (nil without a benchmark)
  # - vs_benchmark_edge_pct total_return_pct − benchmark_return_pct (nil if either is)
  # - max_drawdown_pct     the deepest inception-to-date drawdown (all-time peak)
  #
  # All arithmetic is BigDecimal. An empty portfolio yields a well-formed zero
  # payload, never an error.
  class Summary
    Result = Data.define(
      :current_value, :net_deposits, :total_return, :total_return_pct,
      :benchmark_return_pct, :vs_benchmark_edge_pct, :max_drawdown_pct, :as_of
    )

    def self.call(...) = new(...).call

    def initialize(portfolio:)
      @portfolio = portfolio
    end

    def call
      inception = portfolio.transactions.minimum(:executed_on)
      last_day  = Trading::Calendar.last_day
      return empty if inception.nil? || last_day.nil? || last_day < inception

      valuation = Portfolios::Valuation.call(portfolio: portfolio, from: inception, to: last_day)
      return empty if valuation.candles.empty?

      current_value    = valuation.candles.last.close
      net_deposits     = valuation.flows.sum(BigDecimal(0), &:net)
      total_return     = current_value - net_deposits
      total_return_pct = pct(total_return, net_deposits)
      max_drawdown_pct = valuation.drawdown.map(&:value).min || BigDecimal(0)

      benchmark_return_pct = benchmark_return_pct(inception, last_day, net_deposits)
      edge = total_return_pct && benchmark_return_pct ? total_return_pct - benchmark_return_pct : nil

      Result.new(
        current_value: current_value,
        net_deposits: net_deposits,
        total_return: total_return,
        total_return_pct: total_return_pct,
        benchmark_return_pct: benchmark_return_pct,
        vs_benchmark_edge_pct: edge,
        max_drawdown_pct: max_drawdown_pct,
        as_of: valuation.candles.last.date
      )
    end

    private

    attr_reader :portfolio

    # A return percentage is only meaningful against a positive invested base;
    # a zero/negative net-deposit denominator yields nil rather than Infinity.
    def pct(numerator, denominator)
      return nil unless denominator&.positive?

      (numerator / denominator).round(8)
    end

    def benchmark_return_pct(inception, last_day, net_deposits)
      return nil if portfolio.benchmark.nil?

      sim = Benchmarks::Simulation.call(portfolio: portfolio, from: inception, to: last_day)
      return nil if sim.values.empty?

      pct(sim.values.last.value - net_deposits, net_deposits)
    end

    def empty
      Result.new(
        current_value: BigDecimal(0), net_deposits: BigDecimal(0),
        total_return: BigDecimal(0), total_return_pct: nil,
        benchmark_return_pct: nil, vs_benchmark_edge_pct: nil,
        max_drawdown_pct: BigDecimal(0), as_of: nil
      )
    end
  end
end
