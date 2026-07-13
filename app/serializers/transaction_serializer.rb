# Hand-rolled serializer PORO (no jbuilder/AMS) — presentation layer only.
# One transaction row (backlog #028, docs/PLAN.md § API contract). The
# instrument is exposed as both instrument_id and its symbol (the SPA lists and
# edits transactions by ticker). shares/price/fees are serialized as STRINGS,
# never JSON floats, to preserve the numeric/BigDecimal invariant end-to-end.
class TransactionSerializer
  def initialize(transaction)
    @transaction = transaction
  end

  def as_json(*)
    {
      id: @transaction.id,
      portfolio_id: @transaction.portfolio_id,
      instrument_id: @transaction.instrument_id,
      symbol: @transaction.instrument.symbol,
      side: @transaction.side,
      kind: @transaction.kind,
      shares: @transaction.shares.to_s("F"),
      price: @transaction.price.to_s("F"),
      fees: @transaction.fees.to_s("F"),
      executed_on: @transaction.executed_on.iso8601,
      notes: @transaction.notes,
      recurring_transaction_id: @transaction.recurring_transaction_id,
      created_at: @transaction.created_at.iso8601,
      updated_at: @transaction.updated_at.iso8601
    }
  end
end
