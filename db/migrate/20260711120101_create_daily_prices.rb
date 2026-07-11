class CreateDailyPrices < ActiveRecord::Migration[8.1]
  def change
    create_table :daily_prices do |t|
      # Price rows are instrument-owned: cascade with the instrument.
      # No standalone FK index — the composite unique index below covers
      # every instrument_id access path via its leftmost column.
      t.references :instrument, null: false, index: false,
                   foreign_key: { on_delete: :cascade }
      t.date :date, null: false

      # Raw, unadjusted OHLC (PLAN.md: splits are events, prices stay raw).
      t.decimal :open,  precision: 16, scale: 6, null: false
      t.decimal :high,  precision: 16, scale: 6, null: false
      t.decimal :low,   precision: 16, scale: 6, null: false
      t.decimal :close, precision: 16, scale: 6, null: false
      t.bigint :volume
      t.string :source, null: false

      t.timestamps

      t.check_constraint "high >= low AND low > 0",
                         name: "daily_prices_high_low_check"
    end

    # The workhorse index: upsert_all conflict target AND (instrument_id, date)
    # range scans for the valuation sweep.
    add_index :daily_prices, [:instrument_id, :date], unique: true
  end
end
