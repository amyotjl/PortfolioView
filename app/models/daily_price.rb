class DailyPrice < ApplicationRecord
  belongs_to :instrument

  validates :date, presence: true
  # Mirrors UNIQUE (instrument_id, date). Batch ingestion bypasses this via
  # upsert_all against the same index — that is the intended write path.
  validates :date, uniqueness: { scope: :instrument_id }
  validates :open, :high, :low, :close, presence: true
  validates :low, numericality: { greater_than: 0 }, allow_nil: true
  # Mirrors CHECK (high >= low AND low > 0).
  validates :high, comparison: { greater_than_or_equal_to: :low },
            if: -> { high.present? && low.present? }
  validates :source, presence: true
end
