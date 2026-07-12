# Hand-rolled serializer PORO (no jbuilder/AMS) — presentation layer only.
# One autocomplete suggestion from the local symbol directory. No id: the
# directory row is an internal cache artifact; transactions are POSTed by
# symbol (docs/PLAN.md § API contract).
class ListedInstrumentSerializer
  def initialize(listed_instrument)
    @listed_instrument = listed_instrument
  end

  def as_json(*)
    {
      symbol: @listed_instrument.symbol,
      name: @listed_instrument.name,
      exchange: @listed_instrument.exchange,
      asset_type: @listed_instrument.asset_type,
      currency: @listed_instrument.currency
    }
  end
end
