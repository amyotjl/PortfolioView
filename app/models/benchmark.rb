# Curated benchmark list (seeded: SPY, VTI, QQQ) backing the cash-flow-matched
# comparison line.
#
# Naming note: Ruby's stdlib `benchmark` default gem also defines a top-level
# Benchmark module, but nothing in this app's bundle requires it (verified —
# ActiveSupport 8.1 dropped its Benchmark usage, and no installed gem requires
# "benchmark"). If a future dependency ever loads it, this model must be
# renamed (the stdlib require would raise TypeError against this class).
class Benchmark < ApplicationRecord
  belongs_to :instrument
  # Mirrors portfolios.benchmark_id ON DELETE RESTRICT.
  has_many :portfolios, dependent: :restrict_with_error

  validates :name, presence: true, uniqueness: true
  # Mirrors the unique index on instrument_id (one benchmark per instrument).
  validates :instrument_id, uniqueness: true
end
