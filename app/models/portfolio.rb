class Portfolio < ApplicationRecord
  belongs_to :user
  belongs_to :benchmark, optional: true

  # DB-level ON DELETE CASCADE owns the cleanup when a portfolio goes.
  has_many :transactions
  has_many :recurring_transactions
  has_many :cash_transactions

  # Portfolios that "hold" an instrument — i.e. trade it or have a recurring
  # rule on it. Used by the backfill job to bump series_version on completion
  # (docs/PLAN.md § Caching / § Price pipeline).
  scope :holding, ->(instrument) {
    where(id: Transaction.where(instrument: instrument).select(:portfolio_id))
      .or(where(id: RecurringTransaction.where(instrument: instrument).select(:portfolio_id)))
  }

  validates :name, presence: true
  # Mirrors UNIQUE (user_id, name).
  validates :name, uniqueness: { scope: :user_id }
  validates :series_version, presence: true,
            numericality: { only_integer: true, greater_than_or_equal_to: 1 }
  # A submitted benchmark_id must reference a curated benchmarks row (backlog
  # #027) — otherwise the insert would surface as an FK-violation 500. Error
  # keyed on :benchmark_id so the 422 details map onto the form field.
  validate :benchmark_must_be_curated, if: -> { benchmark_id.present? }

  # ONE predicate governs the entire cash basis (issue #80): a portfolio tracks
  # cash iff it has at least one cash_transactions row. Tracked ⇒ total value
  # includes cash, flows are cash movements, net_deposits is the deposit ledger,
  # the benchmark matches deposits. Untracked ⇒ every code path is exactly
  # today's, so no existing portfolio's numbers move. Deriving this from the
  # rows rather than a flag column is what makes back-compat structural — there
  # is no second source of truth that could disagree with the ledger.
  def cash_tracked? = cash_transactions.exists?

  private

  def benchmark_must_be_curated
    errors.add(:benchmark_id, "must reference a curated benchmark") if benchmark.nil?
  end
end
