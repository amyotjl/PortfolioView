class CreateTransactions < ActiveRecord::Migration[8.1]
  def change
    create_table :transactions do |t|
      # User-owned (via portfolio): cascade. No standalone portfolio_id
      # index — the (portfolio_id, executed_on) sweep index covers it.
      t.references :portfolio, null: false, index: false,
                   foreign_key: { on_delete: :cascade }
      # RESTRICT: an instrument with recorded trades can never be deleted.
      t.references :instrument, null: false, foreign_key: { on_delete: :restrict }

      t.string :side, null: false
      t.string :kind, null: false, default: "normal"
      t.decimal :shares, precision: 20, scale: 8, null: false
      t.decimal :price, precision: 16, scale: 6, null: false
      t.decimal :fees, precision: 12, scale: 2, null: false, default: 0
      t.date :executed_on, null: false
      t.text :notes

      # Materialization linkage. NULLIFY: deleting a recurring rule must
      # never delete the real trades it created. No standalone FK index —
      # the partial unique index below covers it leftmost.
      t.references :recurring_transaction, index: false,
                   foreign_key: { on_delete: :nullify }
      t.date :scheduled_for

      t.timestamps

      t.check_constraint "side IN ('buy', 'sell')", name: "transactions_side_check"
      t.check_constraint "kind IN ('normal', 'dividend_reinvestment')",
                         name: "transactions_kind_check"
      t.check_constraint "shares > 0", name: "transactions_shares_positive"
      t.check_constraint "price > 0", name: "transactions_price_positive"
      t.check_constraint "fees >= 0", name: "transactions_fees_nonnegative"
    end

    # Valuation sweep hot path (PLAN.md: transactions by portfolio and date).
    add_index :transactions, [:portfolio_id, :executed_on]

    # Recurring-materialization idempotency guard: one materialized
    # transaction per (rule, slot). Partial so manual transactions
    # (NULL rule) are unconstrained.
    add_index :transactions, [:recurring_transaction_id, :scheduled_for],
              unique: true,
              where: "recurring_transaction_id IS NOT NULL",
              name: "index_transactions_on_recurring_slot"
  end
end
