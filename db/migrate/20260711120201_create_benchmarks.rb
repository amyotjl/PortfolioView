class CreateBenchmarks < ActiveRecord::Migration[8.1]
  def change
    create_table :benchmarks do |t|
      # Curated seeded list (SPY, VTI, QQQ...) mapping to instrument rows.
      # RESTRICT: an instrument backing a benchmark must not be deletable.
      # One benchmark per instrument, so the FK index is unique.
      t.references :instrument, null: false, index: { unique: true },
                   foreign_key: { on_delete: :restrict }
      t.string :name, null: false

      t.timestamps
    end

    add_index :benchmarks, :name, unique: true
  end
end
