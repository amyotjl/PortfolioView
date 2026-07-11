# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_07_11_120302) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "citext"
  enable_extension "pg_catalog.plpgsql"

  create_table "benchmarks", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "instrument_id", null: false
    t.string "name", null: false
    t.datetime "updated_at", null: false
    t.index ["instrument_id"], name: "index_benchmarks_on_instrument_id", unique: true
    t.index ["name"], name: "index_benchmarks_on_name", unique: true
  end

  create_table "daily_prices", force: :cascade do |t|
    t.decimal "close", precision: 16, scale: 6, null: false
    t.datetime "created_at", null: false
    t.date "date", null: false
    t.decimal "high", precision: 16, scale: 6, null: false
    t.bigint "instrument_id", null: false
    t.decimal "low", precision: 16, scale: 6, null: false
    t.decimal "open", precision: 16, scale: 6, null: false
    t.string "source", null: false
    t.datetime "updated_at", null: false
    t.bigint "volume"
    t.index ["instrument_id", "date"], name: "index_daily_prices_on_instrument_id_and_date", unique: true
    t.check_constraint "high >= low AND low > 0::numeric", name: "daily_prices_high_low_check"
  end

  create_table "dividend_events", force: :cascade do |t|
    t.decimal "cash_per_share", precision: 16, scale: 6, null: false
    t.datetime "created_at", null: false
    t.date "ex_date", null: false
    t.bigint "instrument_id", null: false
    t.datetime "updated_at", null: false
    t.index ["instrument_id", "ex_date"], name: "index_dividend_events_on_instrument_id_and_ex_date", unique: true
    t.check_constraint "cash_per_share > 0::numeric", name: "dividend_events_cash_per_share_positive"
  end

  create_table "instruments", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "currency", default: "USD", null: false
    t.date "earliest_price_on"
    t.string "industry"
    t.string "instrument_type", null: false
    t.date "latest_price_on"
    t.string "name"
    t.datetime "prices_backfilled_at"
    t.string "sector"
    t.string "symbol", null: false
    t.datetime "updated_at", null: false
    t.index "upper((symbol)::text)", name: "index_instruments_on_upper_symbol", unique: true
    t.check_constraint "instrument_type::text = ANY (ARRAY['stock'::character varying, 'etf'::character varying]::text[])", name: "instruments_instrument_type_check"
  end

  create_table "listed_instruments", force: :cascade do |t|
    t.string "asset_type"
    t.datetime "created_at", null: false
    t.string "currency"
    t.string "exchange"
    t.string "name"
    t.string "symbol", null: false
    t.datetime "updated_at", null: false
    t.index "upper((symbol)::text) text_pattern_ops", name: "index_listed_instruments_on_upper_symbol_pattern"
    t.index ["symbol", "exchange"], name: "index_listed_instruments_on_symbol_and_exchange", unique: true, nulls_not_distinct: true
  end

  create_table "portfolios", force: :cascade do |t|
    t.bigint "benchmark_id"
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.integer "series_version", default: 1, null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["benchmark_id"], name: "index_portfolios_on_benchmark_id"
    t.index ["user_id", "name"], name: "index_portfolios_on_user_id_and_name", unique: true
  end

  create_table "recurring_transactions", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.string "amount_type", null: false
    t.date "anchor_on", null: false
    t.integer "consecutive_skips", default: 0, null: false
    t.datetime "created_at", null: false
    t.decimal "dollar_amount", precision: 12, scale: 2
    t.date "end_on"
    t.string "frequency", null: false
    t.bigint "instrument_id", null: false
    t.date "next_run_on", null: false
    t.string "paused_reason"
    t.bigint "portfolio_id", null: false
    t.decimal "share_amount", precision: 20, scale: 8
    t.string "side", default: "buy", null: false
    t.datetime "updated_at", null: false
    t.index ["instrument_id"], name: "index_recurring_transactions_on_instrument_id"
    t.index ["next_run_on"], name: "index_recurring_transactions_on_next_run_on_active", where: "active"
    t.index ["portfolio_id"], name: "index_recurring_transactions_on_portfolio_id"
    t.check_constraint "amount_type::text = 'dollars'::text AND COALESCE(dollar_amount, 0::numeric) > 0::numeric AND share_amount IS NULL OR amount_type::text = 'shares'::text AND COALESCE(share_amount, 0::numeric) > 0::numeric AND dollar_amount IS NULL", name: "recurring_transactions_amount_presence_check"
    t.check_constraint "amount_type::text = ANY (ARRAY['dollars'::character varying, 'shares'::character varying]::text[])", name: "recurring_transactions_amount_type_check"
    t.check_constraint "consecutive_skips >= 0", name: "recurring_transactions_skips_check"
    t.check_constraint "frequency::text = ANY (ARRAY['weekly'::character varying, 'biweekly'::character varying, 'monthly'::character varying, 'quarterly'::character varying]::text[])", name: "recurring_transactions_frequency_check"
    t.check_constraint "side::text = ANY (ARRAY['buy'::character varying, 'sell'::character varying]::text[])", name: "recurring_transactions_side_check"
  end

  create_table "sessions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "ip_address"
    t.datetime "updated_at", null: false
    t.string "user_agent"
    t.bigint "user_id", null: false
    t.index ["user_id"], name: "index_sessions_on_user_id"
  end

  create_table "split_events", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.date "ex_date", null: false
    t.bigint "instrument_id", null: false
    t.decimal "ratio", precision: 12, scale: 6, null: false
    t.datetime "updated_at", null: false
    t.index ["instrument_id", "ex_date"], name: "index_split_events_on_instrument_id_and_ex_date", unique: true
    t.check_constraint "ratio > 0::numeric", name: "split_events_ratio_positive"
  end

  create_table "transactions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.date "executed_on", null: false
    t.decimal "fees", precision: 12, scale: 2, default: "0.0", null: false
    t.bigint "instrument_id", null: false
    t.string "kind", default: "normal", null: false
    t.text "notes"
    t.bigint "portfolio_id", null: false
    t.decimal "price", precision: 16, scale: 6, null: false
    t.bigint "recurring_transaction_id"
    t.date "scheduled_for"
    t.decimal "shares", precision: 20, scale: 8, null: false
    t.string "side", null: false
    t.datetime "updated_at", null: false
    t.index ["instrument_id"], name: "index_transactions_on_instrument_id"
    t.index ["portfolio_id", "executed_on"], name: "index_transactions_on_portfolio_id_and_executed_on"
    t.index ["recurring_transaction_id", "scheduled_for"], name: "index_transactions_on_recurring_slot", unique: true, where: "(recurring_transaction_id IS NOT NULL)"
    t.check_constraint "fees >= 0::numeric", name: "transactions_fees_nonnegative"
    t.check_constraint "kind::text = ANY (ARRAY['normal'::character varying, 'dividend_reinvestment'::character varying]::text[])", name: "transactions_kind_check"
    t.check_constraint "price > 0::numeric", name: "transactions_price_positive"
    t.check_constraint "shares > 0::numeric", name: "transactions_shares_positive"
    t.check_constraint "side::text = ANY (ARRAY['buy'::character varying, 'sell'::character varying]::text[])", name: "transactions_side_check"
  end

  create_table "users", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.citext "email_address", null: false
    t.string "password_digest", null: false
    t.datetime "updated_at", null: false
    t.index ["email_address"], name: "index_users_on_email_address", unique: true
  end

  add_foreign_key "benchmarks", "instruments", on_delete: :restrict
  add_foreign_key "daily_prices", "instruments", on_delete: :cascade
  add_foreign_key "dividend_events", "instruments", on_delete: :cascade
  add_foreign_key "portfolios", "benchmarks", on_delete: :restrict
  add_foreign_key "portfolios", "users", on_delete: :cascade
  add_foreign_key "recurring_transactions", "instruments", on_delete: :restrict
  add_foreign_key "recurring_transactions", "portfolios", on_delete: :cascade
  add_foreign_key "sessions", "users"
  add_foreign_key "split_events", "instruments", on_delete: :cascade
  add_foreign_key "transactions", "instruments", on_delete: :restrict
  add_foreign_key "transactions", "portfolios", on_delete: :cascade
  add_foreign_key "transactions", "recurring_transactions", on_delete: :nullify
end
