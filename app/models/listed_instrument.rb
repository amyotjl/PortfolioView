# Local symbol directory imported weekly from Tiingo's supported_tickers.csv
# (PLAN.md § Database schema). Backs ticker autocomplete and transaction-form
# validation without burning API quota.
class ListedInstrument < ApplicationRecord
  normalizes :symbol, with: ->(s) { s.strip.upcase }

  validates :symbol, presence: true
  # Mirrors the unique (symbol, exchange) NULLS NOT DISTINCT index.
  validates :symbol, uniqueness: { scope: :exchange }
end
