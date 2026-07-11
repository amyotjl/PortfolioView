class CreateSplitEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :split_events do |t|
      t.references :instrument, null: false, index: false,
                   foreign_key: { on_delete: :cascade }
      t.date :ex_date, null: false

      # Tiingo's decimal splitFactor stored directly (no integer
      # rationalizing of 10:9 oddities) — PLAN.md § Database schema.
      t.decimal :ratio, precision: 12, scale: 6, null: false

      t.timestamps

      # A zero/negative factor would poison the cumulative split product.
      t.check_constraint "ratio > 0", name: "split_events_ratio_positive"
    end

    add_index :split_events, [:instrument_id, :ex_date], unique: true
  end
end
