# Hand-rolled serializer PORO (no jbuilder/AMS) for the frozen /candles shape
# (docs/PLAN.md § API contract):
#
#   candles:   [{ t, o, h, l, c }]          portfolio OHLC (HOLDINGS ONLY, always)
#   benchmark: { symbol, values: [{ t, v }] } | null   a close-value LINE, never candles
#   flows:     [{ t, net, items: [{ ticker, kind, amount }] }]   DRIP already excluded upstream
#   drawdown:  [{ t, v }]                    inception all-time-peak fractions
#   cash:      [{ t, v }] | null             SIGNED END-OF-DAY balance, null <=> untracked
#   meta:      { partial, filled_dates, benchmark_clamped, approximation,
#                flow_basis, cash_negative, cash_negative_since }
#
# All money is serialized as STRINGS (cents), never JSON floats; drawdown values
# are fractions kept to 8 dp. flow item `kind` carries the trade side (buy/sell)
# on the trade basis and the CASH KIND (deposit/withdrawal) on the cash basis, and
# `ticker` is null for a cash movement — so consumers must model it as a plain
# string, not an enum, and color the bars by the SIGN of `amount` as they already
# do (issue #80).
#
# `cash` is null, not [], for a portfolio that does not track cash: "does not
# track cash" and "tracks cash and was flat all week" are different states.
class CandlesSerializer
  def initialize(report)
    @report = report
  end

  def as_json(*)
    {
      candles: @report.candles.map do |c|
        { t: c.date.iso8601, o: money(c.open), h: money(c.high), l: money(c.low), c: money(c.close) }
      end,
      benchmark: benchmark_json,
      flows: @report.flows.map do |f|
        {
          t: f.date.iso8601,
          net: money(f.net),
          items: f.items.map { |i| { ticker: i.symbol, kind: i.side, amount: money(i.amount) } }
        }
      end,
      drawdown: @report.drawdown.map { |d| { t: d.date.iso8601, v: fraction(d.value) } },
      cash: @report.cash&.map { |p| { t: p.date.iso8601, v: money(p.value) } },
      meta: {
        partial: @report.meta[:partial],
        filled_dates: @report.meta[:filled_dates].map(&:iso8601),
        benchmark_clamped: @report.meta[:benchmark_clamped],
        approximation: @report.meta[:approximation],
        flow_basis: @report.meta[:flow_basis],
        cash_negative: @report.meta[:cash_negative],
        cash_negative_since: @report.meta[:cash_negative_since]&.iso8601
      }
    }
  end

  private

  def benchmark_json
    return nil if @report.benchmark.nil?

    {
      symbol: @report.benchmark.symbol,
      values: @report.benchmark.values.map { |p| { t: p.date.iso8601, v: money(p.value) } }
    }
  end

  def money(value)
    value.round(2).to_s("F")
  end

  def fraction(value)
    value.round(8).to_s("F")
  end
end
