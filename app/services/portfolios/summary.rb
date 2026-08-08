module Portfolios
  # Lifetime stat-tile figures (docs/PLAN.md § API contract: "lifetime stat
  # tiles … tiles never come from a windowed candles payload"). Everything is
  # computed over the FULL history — inception (first transaction) to the last
  # trading day — via Portfolios::Valuation + Benchmarks::Simulation, never a
  # requested window.
  #
  # - current_value        holdings + cash when cash is tracked, else holdings
  # - holdings_value       the last full-history close (holdings only, always)
  # - cash_balance         the signed closing cash balance, or NIL when the
  #                        portfolio does not track cash
  # - net_deposits         Σ external flows — Σ deposits − Σ withdrawals on the
  #                        cash basis, Σ trade cost (buys +cost+fees, sells
  #                        -proceeds+fees, DRIP excluded) otherwise
  # - deposit_basis        "cash" | "trades" — which of the two the figures above
  #                        are on, so the SPA never has to guess
  # - total_return         current_value − net_deposits (dollars)
  # - total_return_pct     total_return / net_deposits (nil when net_deposits ≤ 0)
  # - benchmark_return_pct the cash-flow-matched shadow ETF's return on the SAME
  #                        deposits (nil without a benchmark)
  # - vs_benchmark_edge_pct total_return_pct − benchmark_return_pct (nil if either is)
  # - max_drawdown_pct     the deepest inception-to-date drawdown (all-time peak)
  # - cash_negative        the balance went below zero at some point (a warning,
  #                        never a rejection) / cash_negative_since names the day
  #
  # CASH_BALANCE IS NIL, NEVER ZERO, WHEN UNTRACKED (issue #80): nil means "this
  # portfolio does not track cash", "0.00" means "it tracks cash and is exactly
  # flat". Both states are reachable and they mean different things — a single
  # `?? 0` anywhere in the chain turns every pre-#80 portfolio's dashboard into a
  # lie.
  #
  # current_value includes cash precisely BECAUSE net_deposits switches basis
  # with it: switching the denominator alone reports a fabricated loss of exactly
  # the idle cash (deposit $1,000, buy $900 of stock => 900 − 1000 = −$100).
  #
  # All arithmetic is BigDecimal. An empty portfolio yields a well-formed zero
  # payload, never an error.
  class Summary
    TRADE_BASIS = "trades".freeze
    CASH_BASIS  = "cash".freeze

    Result = Data.define(
      :current_value, :holdings_value, :cash_balance, :net_deposits, :deposit_basis,
      :total_return, :total_return_pct, :benchmark_return_pct, :vs_benchmark_edge_pct,
      :max_drawdown_pct, :cash_negative, :cash_negative_since, :as_of
    )

    def self.call(...) = new(...).call

    def initialize(portfolio:)
      @portfolio = portfolio
    end

    def call
      inception = inception_on
      last_day  = Trading::Calendar.last_day
      return empty if inception.nil? || last_day.nil? || last_day < inception

      valuation = Portfolios::Valuation.call(portfolio: portfolio, from: inception, to: last_day)
      return empty if valuation.candles.empty?

      cash = valuation.cash
      holdings_value = valuation.candles.last.close
      cash_balance   = cash.tracked ? cash.closing_balance : nil
      current_value  = holdings_value + (cash_balance || BigDecimal(0))

      # UNCHANGED on purpose: the basis switch happens inside Valuation#build_flows,
      # not here, so there is exactly one place that decides what a "flow" is.
      net_deposits     = valuation.flows.sum(BigDecimal(0), &:net)
      total_return     = current_value - net_deposits
      total_return_pct = pct(total_return, net_deposits)
      max_drawdown_pct = valuation.drawdown.map(&:value).min || BigDecimal(0)

      benchmark_return_pct = benchmark_return_pct(inception, last_day, net_deposits)
      edge = total_return_pct && benchmark_return_pct ? total_return_pct - benchmark_return_pct : nil

      Result.new(
        current_value: current_value,
        holdings_value: holdings_value,
        cash_balance: cash_balance,
        net_deposits: net_deposits,
        deposit_basis: cash.tracked ? CASH_BASIS : TRADE_BASIS,
        total_return: total_return,
        total_return_pct: total_return_pct,
        benchmark_return_pct: benchmark_return_pct,
        vs_benchmark_edge_pct: edge,
        max_drawdown_pct: max_drawdown_pct,
        cash_negative: !cash.first_negative_on.nil?,
        cash_negative_since: cash.first_negative_on,
        as_of: valuation.candles.last.date
      )
    end

    private

    attr_reader :portfolio

    # The earlier of the first trade and the first cash movement — a deposit
    # predating the first trade would otherwise be dropped from the window and
    # net_deposits would silently understate (the same live bug fixed in
    # Valuation and CandlesController#default_from).
    def inception_on
      [ portfolio.transactions.minimum(:executed_on),
        portfolio.cash_transactions.minimum(:occurred_on) ].compact.min
    end

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

    # Nothing to value yet (no transactions, no cash, or no trading calendar):
    # a well-formed zero payload on the TRADE basis with cash_balance nil, which
    # keeps the cross-endpoint invariant (deposit_basis == "cash" iff
    # cash_balance != null) true even here.
    def empty
      Result.new(
        current_value: BigDecimal(0), holdings_value: BigDecimal(0), cash_balance: nil,
        net_deposits: BigDecimal(0), deposit_basis: TRADE_BASIS,
        total_return: BigDecimal(0), total_return_pct: nil,
        benchmark_return_pct: nil, vs_benchmark_edge_pct: nil,
        max_drawdown_pct: BigDecimal(0),
        cash_negative: false, cash_negative_since: nil, as_of: nil
      )
    end
  end
end
