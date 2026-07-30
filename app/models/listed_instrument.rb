# Local symbol directory imported weekly from Tiingo's supported_tickers.csv
# (PLAN.md § Database schema). Backs ticker autocomplete and transaction-form
# validation without burning API quota.
class ListedInstrument < ApplicationRecord
  # Bounded autocomplete page (backlog #026): plenty for a type-ahead, small
  # enough that a broad prefix can't dump the directory.
  SEARCH_LIMIT = 20

  # Tiingo supported_tickers exchange codes considered US venues for v1. Lives
  # here rather than on Instruments::DirectoryResolver (which aliases it for
  # backward compatibility) because it describes a property of DIRECTORY ROWS,
  # and two readers now need it: the resolver, to decide what may become an
  # Instrument, and #search, to rank rows the resolver would accept above rows
  # it would reject. Non-US listings and non-USD rows are out of scope until
  # multi-currency support lands (docs/PLAN.md § Deferred to v1.1+).
  US_EXCHANGES = [
    "NYSE", "NASDAQ", "AMEX", "NYSE ARCA", "NYSE MKT", "BATS", "IEX", "CBOE"
  ].to_set.freeze

  # Mutual funds are 46% of the directory (49,001 of 106,253) and share the
  # dense 5-letter X-suffixed namespace, so a plain alphabetical prefix sort
  # buries ordinary equities under them — this is what hid MSFT behind
  # MSFAX/MSFBX/… (issue #63).
  MUTUAL_FUND_PATTERN = "%mutual fund%".freeze

  # A row this app can actually turn into a tradeable Instrument. Anything else
  # (NMFQS, PINK, OTCGREY, a non-USD listing) is un-addable: picking it in the
  # autocomplete only earns a 422 from DirectoryResolver, so it must never
  # outrank a row that works.
  scope :tradeable, -> {
    where(currency: "USD").where("upper(btrim(exchange)) IN (?)", US_EXCHANGES.to_a)
  }

  normalizes :symbol, with: ->(s) { s.strip.upcase }

  validates :symbol, presence: true
  # Mirrors the unique (symbol, exchange) NULLS NOT DISTINCT index.
  validates :symbol, uniqueness: { scope: :exchange }

  # Ticker autocomplete against the LOCAL directory only — no provider HTTP
  # (docs/PLAN.md § API contract). Matches symbol by prefix (served by the
  # upper(symbol) text_pattern_ops index) and name by case-insensitive
  # substring. LIKE metacharacters in the query are escaped, so "BRK%" can't
  # wildcard-match the whole table.
  #
  # Ranked on four tiers, in order (issue #63). The match band alone was not
  # enough: the result set is capped at SEARCH_LIMIT, so with a purely
  # alphabetical tie-break a dense prefix silently truncates the one row the
  # user meant. Searching "MSF" returned MSF, MSFAX, MSFBX … MSFN and **MSFT
  # never appeared at all** — verified live against the real 106,253-row
  # directory.
  #
  #   1. match band     — exact symbol, then symbol prefix, then name-only
  #   2. tradeable      — rows DirectoryResolver would accept, before rows it
  #                       would reject with a 422
  #   3. asset class    — ordinary equities/ETFs before mutual funds
  #   4. symbol length  — shorter tickers are the more prominent listing
  #
  # ...then alphabetically, so the order is total and the output deterministic.
  def self.search(query, limit: SEARCH_LIMIT)
    q = query.to_s.strip
    return none if q.empty?

    symbol_prefix = "#{sanitize_sql_like(q.upcase)}%"
    name_term = "%#{sanitize_sql_like(q)}%"

    where("upper(symbol) LIKE :prefix OR name ILIKE :name", prefix: symbol_prefix, name: name_term)
      .order(Arel.sql(sanitize_sql_array([ <<~SQL.squish, {
        CASE WHEN upper(symbol) = :exact THEN 0
             WHEN upper(symbol) LIKE :prefix THEN 1
             ELSE 2 END,
        CASE WHEN upper(currency) = 'USD' AND upper(btrim(exchange)) IN (:us) THEN 0
             ELSE 1 END,
        CASE WHEN lower(asset_type) LIKE :fund THEN 1 ELSE 0 END,
        length(symbol)
      SQL
        exact: q.upcase, prefix: symbol_prefix,
        us: US_EXCHANGES.to_a, fund: MUTUAL_FUND_PATTERN
      } ])))
      .order(:symbol, :exchange)
      .limit(limit)
  end
end
