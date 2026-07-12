class Instrument < ApplicationRecord
  # Market data rows are instrument-owned: the DB cascades them when an
  # instrument row is deleted, so no dependent option is needed here.
  has_many :daily_prices
  has_many :split_events
  has_many :dividend_events

  # Mirrors benchmarks.instrument_id ON DELETE RESTRICT (unique per instrument).
  has_one :benchmark, dependent: :restrict_with_error

  # Mirrors ON DELETE RESTRICT: an instrument referenced by trades or
  # recurring rules cannot be destroyed.
  has_many :transactions, dependent: :restrict_with_error
  has_many :recurring_transactions, dependent: :restrict_with_error

  # "Active" instruments the nightly sync fans out over: anything referenced by
  # a transaction, a recurring rule, or a benchmark (docs/PLAN.md § Price
  # pipeline). Unreferenced instruments burn no API quota.
  scope :referenced, -> {
    where(id: Transaction.select(:instrument_id))
      .or(where(id: RecurringTransaction.select(:instrument_id)))
      .or(where(id: Benchmark.select(:instrument_id)))
  }

  # Symbols are stored uppercase so the upper(symbol) unique index and all
  # symbol lookups agree on one canonical form.
  normalizes :symbol, with: ->(s) { s.strip.upcase }

  validates :symbol, presence: true
  # Mirrors the unique expression index on upper(symbol).
  validates :symbol, uniqueness: { case_sensitive: false }
  validates :instrument_type, inclusion: { in: %w[stock etf] }
  validates :currency, presence: true

  # First reference to a symbol kicks off its full-history price backfill and a
  # one-time FMP metadata lookup (docs/PLAN.md § Price pipeline). after_create_commit
  # (not after_create) so the jobs never run against a row that a rolled-back
  # transaction never wrote.
  after_create_commit :enqueue_price_backfill
  after_create_commit :enqueue_metadata_fetch

  # Free-tier ETFs/funds have no sector; a nil sector is bucketed here so the
  # allocation pie has one "ETF / Fund" slice instead of an "unknown" hole.
  SECTOR_FALLBACK = "ETF / Fund".freeze

  def sector_label = sector.presence || SECTOR_FALLBACK

  private

  def enqueue_price_backfill
    Prices::BackfillInstrumentJob.perform_later(id)
  end

  def enqueue_metadata_fetch
    Instruments::MetadataJob.perform_later(id)
  end
end
