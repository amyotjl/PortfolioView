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

  # How stale `end_date` may be before a listing counts as dead. Tiingo's
  # endDate is the last date it has prices for, so a live ticker sits within a
  # few days of the file's build date and a delisted one is typically years
  # behind — the window only has to separate those two populations.
  #
  # Deliberately generous, and measured against CURRENT_DATE rather than the
  # directory's own max: if the import ever falls badly behind, every row ages
  # out together, the tier flattens, and ranking degrades to the previous
  # behaviour instead of INVERTING and burying live tickers.
  STALE_LISTING_WINDOW = 180

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
  # Ranked on five tiers, in order (issue #63). The match band alone was not
  # enough: the result set is capped at SEARCH_LIMIT, so with a purely
  # alphabetical tie-break a dense prefix silently truncates the one row the
  # user meant. Searching "MSF" returned MSF, MSFAX, MSFBX … MSFN and **MSFT
  # never appeared at all** — verified live against the real 106,253-row
  # directory.
  #
  #   1. match band     — exact symbol, then symbol prefix, then name-only
  #   2. tradeable      — rows DirectoryResolver would accept, before rows it
  #                       would reject with a 422
  #   3. live           — listings the provider still has recent prices for,
  #                       before delisted ones
  #   4. asset class    — ordinary equities/ETFs before mutual funds
  #   5. symbol length  — shorter tickers are the more prominent listing
  #
  # ...then alphabetically, so the order is total and the output deterministic.
  #
  # Tier 3 exists because tiers 1/2/4/5 were not sufficient either, and the way
  # that surfaced is worth keeping: **50** tradeable non-fund 4-character `AA*`
  # rows compete for 20 slots, and nothing else stored separates AAPL
  # (NASDAQ/Stock/USD) from AABA — Altaba, liquidated in 2019 — which is also
  # NASDAQ/Stock/USD. `search("AA")` returned 20 rows without AAPL. Liveness is
  # the only signal the free directory carries that distinguishes them, and it
  # was being discarded at import until this issue.
  #
  # A NULL `end_date` ranks as LIVE, deliberately: a missing or unparseable date
  # must never be able to hide a real ticker.
  #
  # KNOWN LIMIT — two-character queries. `search("AA")` still does not surface
  # AAPL, and no reordering of these tiers fixes it: more than 20 LIVE, tradeable,
  # non-fund symbols begin "AA" and sort before it, so the answer is excluded by
  # the cap alone. Separating them needs a popularity/liquidity signal the free
  # directory does not carry (measured: dropping the length tier changes nothing
  # for AA/TS/GO/AM/ME). This is acceptable because autocomplete is INCREMENTAL —
  # at three characters all of AAPL, TSLA, GOOGL, AMZN, META, BRK-B, NVDA and SPY
  # are reachable, verified against the live directory. Don't "fix" the 2-char
  # case by weakening a tier; it trades a real improvement for a placebo.
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
        CASE WHEN end_date IS NULL OR end_date >= (CURRENT_DATE - :stale) THEN 0
             ELSE 1 END,
        CASE WHEN lower(asset_type) LIKE :fund THEN 1 ELSE 0 END,
        length(symbol)
      SQL
        exact: q.upcase, prefix: symbol_prefix, us: US_EXCHANGES.to_a,
        stale: STALE_LISTING_WINDOW, fund: MUTUAL_FUND_PATTERN
      } ])))
      .order(:symbol, :exchange)
      .limit(limit)
  end
end
