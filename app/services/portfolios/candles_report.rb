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
  # - `cash` is the END-OF-DAY liquid-cash balance for each emitted candle date,
  #   or NIL when the portfolio does not track cash (issue #80). It is a separate
  #   series, never folded into the candle's O/H/L/C: the candlestick grammar
  #   says "market move", and a deposit drawn as a tall green candle is a lie
  #   about performance. Chart builders discriminate on `cash !== null` read from
  #   the payload they are drawing, never on a flag threaded in from /summary.
  #
  # meta grows flow_basis / cash_negative / cash_negative_since; the other four
  # keys are folded down exactly as before. benchmark_clamped is
  # true when the shadow line is clamped for EITHER reason the simulation can
  # report — an over-withdrawal (benchmark_clamped) or a benchmark history
  # shorter than the portfolio (sim_start_clamped) — since the frozen contract
  # exposes a single clamp flag.
  class CandlesReport
    CashPoint = Data.define(:date, :value)

    Result = Data.define(:candles, :benchmark, :flows, :drawdown, :cash, :meta)

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
        cash: cash_series(valuation),
        meta: merged_meta(valuation, benchmark)
      )
    end

    private

    attr_reader :portfolio, :from, :to, :with_benchmark

    def build_benchmark
      return nil unless with_benchmark && portfolio.benchmark

      Benchmarks::Simulation.call(portfolio: portfolio, from: from, to: to)
    end

    # One point per EMITTED candle date, so the two series are index-aligned for
    # the chart; nil (not []) when untracked, because "does not track cash" and
    # "tracks cash, flat all week" are different states.
    def cash_series(valuation)
      cash = valuation.cash
      return nil unless cash.tracked

      valuation.candles.map { |candle| CashPoint.new(date: candle.date, value: cash.balances.fetch(candle.date, BigDecimal(0))) }.freeze
    end

    def merged_meta(valuation, benchmark)
      cash = valuation.cash
      {
        partial: valuation.meta[:partial] || (benchmark ? !!benchmark.meta[:partial] : false),
        filled_dates: valuation.meta[:filled_dates],
        benchmark_clamped: benchmark ? benchmark_clamped?(benchmark) : false,
        approximation: valuation.meta[:approximation],
        flow_basis: cash.tracked ? "cash" : "trades",
        cash_negative: !cash.first_negative_on.nil?,
        cash_negative_since: cash.first_negative_on
      }
    end

    def benchmark_clamped?(benchmark)
      !!(benchmark.meta[:benchmark_clamped] || benchmark.meta[:sim_start_clamped])
    end
  end
end
