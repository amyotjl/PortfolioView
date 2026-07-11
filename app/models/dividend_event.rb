class DividendEvent < ApplicationRecord
  belongs_to :instrument

  validates :ex_date, presence: true
  # Mirrors UNIQUE (instrument_id, ex_date).
  validates :ex_date, uniqueness: { scope: :instrument_id }
  # Mirrors CHECK (cash_per_share > 0).
  validates :cash_per_share, numericality: { greater_than: 0 }
end
