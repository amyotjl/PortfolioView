class Instrument < ApplicationRecord
  # Market data rows are instrument-owned: the DB cascades them when an
  # instrument row is deleted, so no dependent option is needed here.
  has_many :daily_prices
  has_many :split_events
  has_many :dividend_events

  # Symbols are stored uppercase so the upper(symbol) unique index and all
  # symbol lookups agree on one canonical form.
  normalizes :symbol, with: ->(s) { s.strip.upcase }

  validates :symbol, presence: true
  # Mirrors the unique expression index on upper(symbol).
  validates :symbol, uniqueness: { case_sensitive: false }
  validates :instrument_type, inclusion: { in: %w[stock etf] }
  validates :currency, presence: true
end
