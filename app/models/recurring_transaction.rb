class RecurringTransaction < ApplicationRecord
  # v1 is buy-only (PLAN.md); the DB CHECK allows the full buy/sell domain
  # so v1.1 recurring sells only need this constant relaxed.
  SIDES = %w[buy].freeze
  AMOUNT_TYPES = %w[dollars shares].freeze
  FREQUENCIES = %w[weekly biweekly monthly quarterly].freeze

  belongs_to :portfolio
  belongs_to :instrument
  # Mirrors transactions.recurring_transaction_id ON DELETE SET NULL:
  # materialized trades outlive their rule.
  has_many :transactions, dependent: :nullify

  validates :side, inclusion: { in: SIDES, message: "only buy rules are supported in v1" }
  validates :amount_type, inclusion: { in: AMOUNT_TYPES }
  validates :frequency, inclusion: { in: FREQUENCIES }
  validates :anchor_on, :next_run_on, presence: true
  validates :consecutive_skips, presence: true,
            numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  # Mirrors recurring_transactions_amount_presence_check: exactly one amount,
  # matching the declared mode.
  validates :dollar_amount, numericality: { greater_than: 0 }, if: -> { amount_type == "dollars" }
  validates :share_amount, numericality: { greater_than: 0 }, if: -> { amount_type == "shares" }
  validate :exactly_one_amount_for_mode

  # --- schedule math (docs/PLAN.md § Recurring materializer) ---
  # Slots are ALWAYS computed from the anchor, never from the previous slot,
  # so end-of-month clamping cannot drift: a Jan-31 monthly anchor yields
  # Feb-28 (clamped) then Mar-31 (back on the 31st), not Feb-28 -> Mar-28.
  # Date#>> does the calendar-correct month stepping (incl. leap years).

  def next_slot_after(date)
    case frequency
    when "weekly"    then next_slot_by_days(date, 7)
    when "biweekly"  then next_slot_by_days(date, 14)
    when "monthly"   then next_slot_by_months(date, 1)
    when "quarterly" then next_slot_by_months(date, 3)
    end
  end

  def first_slot_on_or_after(date) = next_slot_after(date - 1)

  private

  def next_slot_by_days(date, step)
    return anchor_on if date < anchor_on
    steps = ((date - anchor_on).to_i / step) + 1
    anchor_on + steps * step
  end

  def next_slot_by_months(date, step)
    return anchor_on if date < anchor_on
    months = (date.year - anchor_on.year) * 12 + (date.month - anchor_on.month)
    steps = [ months / step * step, 0 ].max
    steps += step while (anchor_on >> steps) <= date
    anchor_on >> steps
  end

  def exactly_one_amount_for_mode
    case amount_type
    when "dollars"
      errors.add(:share_amount, "must be blank for dollar-amount rules") if share_amount.present?
    when "shares"
      errors.add(:dollar_amount, "must be blank for share-amount rules") if dollar_amount.present?
    end
  end
end
