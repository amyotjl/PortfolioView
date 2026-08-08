class CashTransaction < ApplicationRecord
  KINDS = %w[deposit withdrawal interest dividend_cash tax fee].freeze

  # External money crossing the account boundary — the only kinds that count
  # toward net_deposits and that the benchmark's shadow ETF matches. Interest,
  # dividend_cash, tax and fee move the BALANCE but are not contributions: the
  # broker paid you (or charged you) *inside* the account. This is the exact
  # generalization of the existing rule that kind: dividend_reinvestment is
  # excluded from external flows and benchmark matching, "otherwise the shadow
  # portfolio gets free money the benchmark side never models"
  # (Benchmarks::Simulation). Adding any of the four internal kinds here would
  # silently turn a broker dividend into a user contribution and understate
  # return — hence the pinning test.
  EXTERNAL_KINDS = %w[deposit withdrawal].freeze

  belongs_to :portfolio

  validates :kind, inclusion: { in: KINDS }
  validates :amount, presence: true
  validates :occurred_on, presence: true

  # Mirrors the cash_transactions_amount_sign CHECK so a bad row is a 422 and
  # not a 500. Storage is signed and the direction lives in `kind`: deposit > 0,
  # withdrawal < 0, the four internal kinds either way but never zero.
  #
  # Deliberately NOT a before_validation that coerces the sign — the API
  # contract puts magnitude→sign conversion at the controller boundary, and a
  # model-level coercion would silently rewrite an importer's legitimately
  # negative dividend_cash reversal or tax refund into its opposite.
  validate :amount_sign_must_match_kind

  # THERE IS DELIBERATELY NO BALANCE VALIDATION HERE, and there must never be
  # one. Negative cash is legal: an imported broker ledger can legitimately
  # leave a portfolio negative, and the decision is that a negative balance is
  # *shown with a warning, never rejected* — no validation, no CHECK, no clamp.
  # Nothing in this model may consult the running balance.
  #
  # Positions::Validator is DELIBERATELY NOT WIRED HERE either. A cash row
  # carries no shares, so it cannot drive a share position negative; leaving it
  # out keeps the invariant "every transaction mutation runs
  # Positions::Validator" literally true of `transactions` rows, rather than
  # diluting it into "…except the arm that does nothing". Both omissions look
  # like bugs otherwise, which is why they are written down.

  # Any cash mutation invalidates cached series (docs/PLAN.md § Caching): bump
  # the owning portfolio's series_version cache-buster, exactly as Transaction
  # does. The *first* cash row additionally flips the portfolio onto the cash
  # basis, which rewrites flows for its whole history — all the more reason the
  # bump cannot be skipped.
  after_create :bump_portfolio_series_version
  after_update :bump_portfolio_series_version
  after_destroy :bump_portfolio_series_version

  private

  def amount_sign_must_match_kind
    return if amount.blank? || !KINDS.include?(kind)

    if amount.zero?
      errors.add(:amount, "must not be zero")
    elsif kind == "deposit" && amount.negative?
      errors.add(:amount, "must be positive for a deposit")
    elsif kind == "withdrawal" && amount.positive?
      errors.add(:amount, "must be negative for a withdrawal")
    end
  end

  def bump_portfolio_series_version
    ids = [ portfolio_id ]
    # An update that moved the cash row between portfolios stales both.
    ids << saved_change_to_portfolio_id.first if saved_change_to_portfolio_id
    Portfolio.where(id: ids.compact.uniq).update_all("series_version = series_version + 1")
  end
end
