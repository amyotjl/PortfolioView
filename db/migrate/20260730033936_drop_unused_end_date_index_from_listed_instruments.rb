# #63 added an index on listed_instruments.end_date claiming it "supports the
# liveness tier in ListedInstrument.search". It does not, and cannot: search
# reads end_date inside a CASE expression in ORDER BY, and a b-tree on the bare
# column cannot serve that. Measured during #63's gate — idx_scan delta was
# ZERO across 200 uncached searches, and EXPLAIN ANALYZE shows a Seq Scan over
# all ~106k rows either way (issue #71).
#
# So it is pure cost: every weekly Directory::ImportJob upserts ~106k rows and
# maintains it for nothing. Dropped rather than left in place with a corrected
# comment, because an index nobody reads is an invitation to "optimize" around
# a thing that was never doing any work.
#
# Search is ~13-14ms on the real directory with or without it. If that ever
# needs to come down, the fix is an expression index matching the actual ORDER
# BY, or a materialized rank column — not this.
class DropUnusedEndDateIndexFromListedInstruments < ActiveRecord::Migration[8.1]
  def change
    remove_index :listed_instruments, :end_date
  end
end
