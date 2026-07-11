class SplitEvent < ApplicationRecord
  belongs_to :instrument

  validates :ex_date, presence: true
  # Mirrors UNIQUE (instrument_id, ex_date).
  validates :ex_date, uniqueness: { scope: :instrument_id }
  # Mirrors CHECK (ratio > 0).
  validates :ratio, numericality: { greater_than: 0 }
end
