class Transaction < ApplicationRecord
  SIDES = %w[buy sell].freeze
  KINDS = %w[normal dividend_reinvestment].freeze

  # Attributes whose change can alter a replayed position — the
  # Positions::Validator guard only re-replays when one of these moves.
  POSITION_ATTRIBUTES = %w[portfolio_id instrument_id side shares executed_on].freeze

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

  # No short positions in v1 (docs/PLAN.md § Core domain logic): every
  # create/update replays the split-adjusted running position and rejects a
  # mutation that would drive it negative on any date — including backdated
  # edits that strand a later sell. Destroys run the same replay minus self.
  validate :position_must_stay_nonnegative, if: :position_relevant_change?
  before_destroy :position_must_survive_removal

  # Any transaction mutation invalidates cached series (docs/PLAN.md
  # § Caching): bump the owning portfolio's series_version cache-buster.
  after_create :bump_portfolio_series_version
  after_update :bump_portfolio_series_version
  after_destroy :bump_portfolio_series_version

  private

  def position_relevant_change?
    new_record? || (changed & POSITION_ATTRIBUTES).any?
  end

  def position_must_stay_nonnegative
    # Field-level validity first: a replay over nil shares/dates is meaningless.
    return if portfolio_id.blank? || instrument_id.blank? || executed_on.blank?
    return if shares.blank? || !SIDES.include?(side)

    affected_position_pairs.each do |pair_portfolio_id, pair_instrument_id, includes_self|
      result = replay_position(pair_portfolio_id, pair_instrument_id, include_self: includes_self)
      next if result.valid?

      errors.add(:base, negative_position_message(pair_instrument_id, result.first_offending_date))
    end
  end

  def position_must_survive_removal
    result = replay_position(portfolio_id, instrument_id, include_self: false)
    return if result.valid?

    errors.add(:base, negative_position_message(instrument_id, result.first_offending_date))
    throw :abort
  end

  # The (portfolio, instrument) timelines this mutation touches: the current
  # pair (with self's proposed values), plus — when an update moves the row to
  # another portfolio/instrument — the pair it is leaving (without self).
  def affected_position_pairs
    pairs = [ [ portfolio_id, instrument_id, true ] ]
    if persisted? && (will_save_change_to_portfolio_id? || will_save_change_to_instrument_id?)
      pairs << [ portfolio_id_in_database, instrument_id_in_database, false ]
    end
    pairs
  end

  def replay_position(pair_portfolio_id, pair_instrument_id, include_self:)
    scope = self.class.where(portfolio_id: pair_portfolio_id, instrument_id: pair_instrument_id)
    scope = scope.where.not(id: id) if persisted?

    entries = scope.pluck(:executed_on, :side, :shares).map do |executed_on, side, shares|
      Positions::Validator::Entry.new(executed_on: executed_on, side: side, shares: shares)
    end
    if include_self
      entries << Positions::Validator::Entry.new(executed_on: executed_on, side: side, shares: shares)
    end

    Positions::Validator.call(instrument_id: pair_instrument_id, transactions: entries)
  end

  def negative_position_message(for_instrument_id, offending_date)
    symbol = Instrument.where(id: for_instrument_id).pick(:symbol) || "instrument ##{for_instrument_id}"
    "would make the #{symbol} position negative on #{offending_date.iso8601}"
  end

  def bump_portfolio_series_version
    ids = [ portfolio_id ]
    # An update that moved the transaction between portfolios stales both.
    ids << saved_change_to_portfolio_id.first if saved_change_to_portfolio_id
    Portfolio.where(id: ids.compact.uniq).update_all("series_version = series_version + 1")
  end
end
