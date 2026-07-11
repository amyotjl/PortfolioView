class CreateRecurringTransactions < ActiveRecord::Migration[8.1]
  def change
    create_table :recurring_transactions do |t|
      # User-owned (via portfolio): cascade. Instrument stays delete-protected.
      t.references :portfolio, null: false, foreign_key: { on_delete: :cascade }
      t.references :instrument, null: false, foreign_key: { on_delete: :restrict }

      # DB constrains side to the enum domain; "buy only in v1" is enforced
      # at the model layer (PLAN.md) so v1.1 recurring sells need no DDL.
      t.string :side, null: false, default: "buy"
      t.string :amount_type, null: false
      t.decimal :dollar_amount, precision: 12, scale: 2
      t.decimal :share_amount, precision: 20, scale: 8
      t.string :frequency, null: false
      t.date :anchor_on, null: false
      t.date :next_run_on, null: false
      t.date :end_on
      t.boolean :active, null: false, default: true
      t.string :paused_reason
      t.integer :consecutive_skips, null: false, default: 0

      t.timestamps

      t.check_constraint "side IN ('buy', 'sell')",
                         name: "recurring_transactions_side_check"
      t.check_constraint "amount_type IN ('dollars', 'shares')",
                         name: "recurring_transactions_amount_type_check"
      t.check_constraint "frequency IN ('weekly', 'biweekly', 'monthly', 'quarterly')",
                         name: "recurring_transactions_frequency_check"
      # Exactly one amount, matching the declared mode. COALESCE keeps SQL
      # three-valued logic from letting a NULL amount slip through the OR
      # (NULL > 0 is NULL, and a CHECK passes on NULL).
      t.check_constraint "(amount_type = 'dollars' AND COALESCE(dollar_amount, 0) > 0 AND share_amount IS NULL) " \
                         "OR (amount_type = 'shares' AND COALESCE(share_amount, 0) > 0 AND dollar_amount IS NULL)",
                         name: "recurring_transactions_amount_presence_check"
      t.check_constraint "consecutive_skips >= 0",
                         name: "recurring_transactions_skips_check"
    end

    # Materializer hot path: WHERE active AND next_run_on <= today.
    add_index :recurring_transactions, :next_run_on, where: "active",
              name: "index_recurring_transactions_on_next_run_on_active"
  end
end
