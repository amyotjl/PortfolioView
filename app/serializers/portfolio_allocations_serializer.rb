# Hand-rolled serializer PORO (no jbuilder/AMS) for GET /portfolios/:id/allocations
# (docs/PLAN.md § API contract). Values are rounded to cents, weights to 6 dp —
# all serialized as STRINGS, never JSON floats. by_instrument and by_sector are
# ordered largest-value first; weights sum to 1 within rounding.
#
# An instrument slice's `sector` is the join key into by_sector (same label, so
# grouping by_instrument on it reproduces by_sector exactly) — the sector treemap
# needs the hierarchy and cannot rebuild it from anywhere else.
class PortfolioAllocationsSerializer
  def initialize(allocations)
    @allocations = allocations
  end

  def as_json(*)
    {
      as_of: @allocations.as_of&.iso8601,
      total_value: money(@allocations.total_value),
      by_instrument: @allocations.by_instrument.map do |slice|
        {
          instrument_id: slice.instrument_id,
          symbol: slice.symbol,
          sector: slice.sector,
          value: money(slice.value),
          weight: weight(slice.weight)
        }
      end,
      by_sector: @allocations.by_sector.map do |slice|
        { sector: slice.sector, value: money(slice.value), weight: weight(slice.weight) }
      end
    }
  end

  private

  def money(value)
    value.round(2).to_s("F")
  end

  def weight(value)
    value.round(6).to_s("F")
  end
end
