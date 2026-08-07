class CreateDividendEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :dividend_events do |t|
      t.references :instrument, null: false, index: false,
                   foreign_key: { on_delete: :cascade }
      t.date :ex_date, null: false

      # Price-like per-share amount — same scale as daily_prices OHLC.
      t.decimal :cash_per_share, precision: 16, scale: 6, null: false

      t.timestamps

      t.check_constraint "cash_per_share > 0",
                         name: "dividend_events_cash_per_share_positive"
    end

    add_index :dividend_events, [ :instrument_id, :ex_date ], unique: true
  end
end
