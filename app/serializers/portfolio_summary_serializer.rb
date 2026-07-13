# Hand-rolled serializer PORO (no jbuilder/AMS) for GET /portfolios/:id/summary
# (docs/PLAN.md § API contract). Dollar figures are rounded to cents, percentages
# to 6 dp — all serialized as STRINGS, never JSON floats (money/shares invariant).
# Undefined figures (e.g. return % with no positive deposit base, or a missing
# benchmark) serialize as null.
class PortfolioSummarySerializer
  def initialize(summary)
    @summary = summary
  end

  def as_json(*)
    {
      current_value: money(@summary.current_value),
      net_deposits: money(@summary.net_deposits),
      total_return: money(@summary.total_return),
      total_return_pct: pct(@summary.total_return_pct),
      benchmark_return_pct: pct(@summary.benchmark_return_pct),
      vs_benchmark_edge_pct: pct(@summary.vs_benchmark_edge_pct),
      max_drawdown_pct: pct(@summary.max_drawdown_pct),
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
