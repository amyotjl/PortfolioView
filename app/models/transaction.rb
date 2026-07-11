class Transaction < ApplicationRecord
  SIDES = %w[buy sell].freeze
  KINDS = %w[normal dividend_reinvestment].freeze

  belongs_to :portfolio
  belongs_to :instrument
  belongs_to :recurring_transaction, optional: true

  validates :side, inclusion: { in: SIDES }
  validates :kind, inclusion: { in: KINDS }
  # Mirror the CHECK constraints: shares > 0, price > 0, fees >= 0.
  validates :shares, numericality: { greater_than: 0 }
  validates :price, numericality: { greater_than: 0 }
  validates :fees, numericality: { greater_than_or_equal_to: 0 }
  validates :executed_on, presence: true

  # Mirrors the partial unique index (materialization idempotency guard).
  validates :scheduled_for, uniqueness: { scope: :recurring_transaction_id },
            if: -> { recurring_transaction_id.present? }
end
