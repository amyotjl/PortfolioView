# Hand-rolled serializer PORO (no jbuilder/AMS) — presentation layer only.
# One recurring rule (backlog #029, docs/PLAN.md § API contract). Exposes the
# lifecycle fields the UI needs to surface a paused rule (active, paused_reason,
# consecutive_skips). Money amounts are serialized as STRINGS (never floats);
# the unused amount for the rule's mode is null.
class RecurringTransactionSerializer
  def initialize(rule)
    @rule = rule
  end

  def as_json(*)
    {
      id: @rule.id,
      portfolio_id: @rule.portfolio_id,
      instrument_id: @rule.instrument_id,
      symbol: @rule.instrument.symbol,
      side: @rule.side,
      amount_type: @rule.amount_type,
      dollar_amount: @rule.dollar_amount&.to_s("F"),
      share_amount: @rule.share_amount&.to_s("F"),
      frequency: @rule.frequency,
      anchor_on: @rule.anchor_on.iso8601,
      next_run_on: @rule.next_run_on.iso8601,
      end_on: @rule.end_on&.iso8601,
      active: @rule.active,
      paused_reason: @rule.paused_reason,
      consecutive_skips: @rule.consecutive_skips,
      created_at: @rule.created_at.iso8601,
      updated_at: @rule.updated_at.iso8601
    }
  end
end
