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

ActiveRecord::Schema[8.1].define(version: 2026_07_11_120103) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "citext"
  enable_extension "pg_catalog.plpgsql"

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

  create_table "users", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.citext "email_address", null: false
    t.string "password_digest", null: false
    t.datetime "updated_at", null: false
    t.index ["email_address"], name: "index_users_on_email_address", unique: true
  end

  add_foreign_key "daily_prices", "instruments", on_delete: :cascade
  add_foreign_key "dividend_events", "instruments", on_delete: :cascade
  add_foreign_key "sessions", "users"
  add_foreign_key "split_events", "instruments", on_delete: :cascade
end
