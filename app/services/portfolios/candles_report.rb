module Portfolios
  # Assembles the /candles payload data (docs/PLAN.md § API contract) from the
  # two domain services, keeping the controller and serializer thin:
  #
  # - portfolio candles + flows + drawdown come from Portfolios::Valuation
  #   (drawdown is inception-to-date, all-time-peak — the service sweeps from
  #   inception even for a later `from` and emits only the window's points).
  # - the benchmark, when requested and configured, comes from
  #   Benchmarks::Simulation as a close-value LINE (never candles — portfolio
  #   H/L are bounds while a single ETF's are real).
  #
  # meta is folded down to exactly the frozen four keys. benchmark_clamped is
  # true when the shadow line is clamped for EITHER reason the simulation can
  # report — an over-withdrawal (benchmark_clamped) or a benchmark history
  # shorter than the portfolio (sim_start_clamped) — since the frozen contract
  # exposes a single clamp flag.
  class CandlesReport
    Result = Data.define(:candles, :benchmark, :flows, :drawdown, :meta)

    def self.call(...) = new(...).call

    def initialize(portfolio:, from:, to:, with_benchmark:)
      @portfolio = portfolio
      @from = from
      @to = to
      @with_benchmark = with_benchmark
    end

    def call
      valuation = Portfolios::Valuation.call(portfolio: portfolio, from: from, to: to)
      benchmark = build_benchmark

      Result.new(
        candles: valuation.candles,
        benchmark: benchmark,
        flows: valuation.flows,
        drawdown: valuation.drawdown,
        meta: merged_meta(valuation, benchmark)
      )
    end

    private

    attr_reader :portfolio, :from, :to, :with_benchmark

    def build_benchmark
      return nil unless with_benchmark && portfolio.benchmark

      Benchmarks::Simulation.call(portfolio: portfolio, from: from, to: to)
    end

    def merged_meta(valuation, benchmark)
      {
        partial: valuation.meta[:partial] || (benchmark ? !!benchmark.meta[:partial] : false),
        filled_dates: valuation.meta[:filled_dates],
        benchmark_clamped: benchmark ? benchmark_clamped?(benchmark) : false,
        approximation: valuation.meta[:approximation]
      }
    end

    def benchmark_clamped?(benchmark)
      !!(benchmark.meta[:benchmark_clamped] || benchmark.meta[:sim_start_clamped])
    end
  end
end
