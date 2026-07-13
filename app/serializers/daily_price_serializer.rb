# Hand-rolled serializer PORO (no jbuilder/AMS) — presentation layer only.
# The transaction-form price prefill: `date` is the actual trading day the
# close belongs to (may be earlier than the requested date — weekend/holiday
# requests resolve to the prior trading day). Money serialized as a string,
# never a JSON float (docs/PLAN.md: prices are numeric/BigDecimal).
class DailyPriceSerializer
  def initialize(daily_price)
    @daily_price = daily_price
  end

  def as_json(*)
    {
      instrument_id: @daily_price.instrument_id,
      date: @daily_price.date.iso8601,
      close: @daily_price.close.to_s("F")
    }
  end
end
