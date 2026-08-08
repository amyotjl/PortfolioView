# Hand-rolled serializer PORO (no jbuilder/AMS) — presentation layer only.
# One cash movement (issue #80).
#
# `amount` is SIGNED on the wire, verbatim as stored, for all six kinds — the
# same rule as cash_balance, cash[].v and flows[].amount, so EVERY money figure
# in this API is signed and there is no per-kind exception to remember.
#
# An unsigned magnitude was considered and rejected: `tax` and `fee` are legally
# either sign under ONE kind name (a withholding vs a refund, a charge vs a
# reimbursement), so magnitude-plus-kind cannot express a refund at all. The HTML
# form is unsigned and converts at the composable boundary, which is the only
# place that needs to.
#
# Money is a STRING, never a JSON float, like every other money field in this API.
class CashTransactionSerializer
  def initialize(cash_transaction)
    @cash_transaction = cash_transaction
  end

  def as_json(*)
    {
      id: @cash_transaction.id,
      portfolio_id: @cash_transaction.portfolio_id,
      kind: @cash_transaction.kind,
      amount: @cash_transaction.amount.to_s("F"),
      occurred_on: @cash_transaction.occurred_on.iso8601,
      notes: @cash_transaction.notes,
      created_at: @cash_transaction.created_at.iso8601,
      updated_at: @cash_transaction.updated_at.iso8601
    }
  end
end
