class CreateInstruments < ActiveRecord::Migration[8.1]
  def change
    create_table :instruments do |t|
      t.string :symbol, null: false
      t.string :name
      t.string :sector
      t.string :industry
      t.string :instrument_type, null: false
      t.string :currency, null: false, default: "USD"

      # Price-cache bookkeeping (PLAN.md § Database schema): set by the
      # backfill/daily-sync jobs, read by the valuation cache key.
      t.datetime :prices_backfilled_at
      t.date :earliest_price_on
      t.date :latest_price_on

      t.timestamps

      t.check_constraint "instrument_type IN ('stock', 'etf')",
                         name: "instruments_instrument_type_check"
    end

    # Case-insensitive symbol identity: lookups go through upper(symbol),
    # so "aapl" can never coexist with "AAPL".
    add_index :instruments, "upper(symbol)", unique: true,
              name: "index_instruments_on_upper_symbol"
  end
end
