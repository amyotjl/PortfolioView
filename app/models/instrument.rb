class Instrument < ApplicationRecord
  # Symbols are stored uppercase so the upper(symbol) unique index and all
  # symbol lookups agree on one canonical form.
  normalizes :symbol, with: ->(s) { s.strip.upcase }

  validates :symbol, presence: true
  # Mirrors the unique expression index on upper(symbol).
  validates :symbol, uniqueness: { case_sensitive: false }
  validates :instrument_type, inclusion: { in: %w[stock etf] }
  validates :currency, presence: true
end
