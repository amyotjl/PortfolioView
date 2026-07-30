# Tiingo's supported_tickers.csv carries `startDate` and `endDate` per row and
# Directory::ImportJob was discarding both. `endDate` is the last date the
# provider has price data for, which makes it the only signal in the whole free
# directory that separates a LIVE listing from a dead one (issue #63).
#
# Why that matters: 50 tradeable non-fund 4-character AA* rows compete for a
# 20-row autocomplete cap, and nothing else stored distinguishes AAPL
# (NASDAQ/Stock/USD) from AABA — Altaba, liquidated in 2019 — which is also
# NASDAQ/Stock/USD. Searching "AA" returned 20 rows without AAPL.
#
# Both nullable: a row whose dates are missing or unparseable must still import
# (the importer's posture is skip-and-count, never fail the run), and NULL is
# ranked as LIVE so a parse gap can never hide a real ticker.
class AddListingDatesToListedInstruments < ActiveRecord::Migration[8.1]
  def change
    add_column :listed_instruments, :start_date, :date
    add_column :listed_instruments, :end_date, :date

    # Supports the liveness tier in ListedInstrument.search, which reads
    # end_date on every keystroke across ~106k rows.
    add_index :listed_instruments, :end_date
  end
end
