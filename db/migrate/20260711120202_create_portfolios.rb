class CreatePortfolios < ActiveRecord::Migration[8.1]
  def change
    create_table :portfolios do |t|
      # User-owned data: cascade with the user. No standalone FK index —
      # the composite unique (user_id, name) below covers it leftmost.
      t.references :user, null: false, index: false,
                   foreign_key: { on_delete: :cascade }
      t.string :name, null: false

      # Optional until the user picks one; RESTRICT so deleting a curated
      # benchmark can never silently drop user configuration.
      t.references :benchmark, foreign_key: { on_delete: :restrict }

      # Cache-buster bumped on any transaction/recurring mutation or
      # backfill completion (PLAN.md § Caching).
      t.integer :series_version, null: false, default: 1

      t.timestamps
    end

    add_index :portfolios, [:user_id, :name], unique: true
  end
end
