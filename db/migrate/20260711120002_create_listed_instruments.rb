class CreateListedInstruments < ActiveRecord::Migration[8.1]
  def change
    create_table :listed_instruments do |t|
      t.string :symbol, null: false
      t.string :name
      t.string :exchange
      t.string :asset_type
      t.string :currency

      t.timestamps
    end

    # Autocomplete hot path: WHERE upper(symbol) LIKE 'PREF%'.
    # text_pattern_ops makes the b-tree usable for prefix LIKE under the
    # database's non-C collation.
    add_index :listed_instruments, "upper(symbol) text_pattern_ops",
              name: "index_listed_instruments_on_upper_symbol_pattern"

    # Conflict target for the weekly Tiingo CSV re-import (upsert_all).
    # NULLS NOT DISTINCT so a NULL exchange cannot smuggle duplicate
    # symbol rows past the unique index.
    add_index :listed_instruments, [ :symbol, :exchange ],
              unique: true, nulls_not_distinct: true,
              name: "index_listed_instruments_on_symbol_and_exchange"
  end
end
