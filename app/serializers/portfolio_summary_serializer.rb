# Hand-rolled serializer PORO (no jbuilder/AMS) for GET /portfolios/:id/summary
# (docs/PLAN.md § API contract). Dollar figures are rounded to cents, percentages
# to 6 dp — all serialized as STRINGS, never JSON floats (money/shares invariant).
# Undefined figures (e.g. return % with no positive deposit base, or a missing
# benchmark) serialize as null.
#
# cash_balance is NULL for a portfolio that does not track cash and a money
# string (including "0.0") for one that does — never defaulted to zero. null
# means "does not track cash"; "0.0" means "tracks cash, exactly flat". Both are
# reachable and they mean different things (issue #80).
class PortfolioSummarySerializer
  def initialize(summary)
    @summary = summary
  end

  def as_json(*)
    {
      current_value: money(@summary.current_value),
      holdings_value: money(@summary.holdings_value),
      cash_balance: money(@summary.cash_balance),
      net_deposits: money(@summary.net_deposits),
      deposit_basis: @summary.deposit_basis,
      total_return: money(@summary.total_return),
      total_return_pct: pct(@summary.total_return_pct),
      benchmark_return_pct: pct(@summary.benchmark_return_pct),
      vs_benchmark_edge_pct: pct(@summary.vs_benchmark_edge_pct),
      max_drawdown_pct: pct(@summary.max_drawdown_pct),
      # Both emitted with NO current frontend reader (the SPA derives negativity
      # from cash_balance so the figure and the warning cannot disagree) — kept
      # deliberately, not dead code. cash_negative_since is the only place the
      # "negative since when" date exists at all; see Portfolios::CashLedger.
      cash_negative: @summary.cash_negative,
      cash_negative_since: @summary.cash_negative_since&.iso8601,
      as_of: @summary.as_of&.iso8601
    }
  end

  private

  def money(value)
    value.nil? ? nil : value.round(2).to_s("F")
  end

  def pct(value)
    value.nil? ? nil : value.round(6).to_s("F")
  end
end
