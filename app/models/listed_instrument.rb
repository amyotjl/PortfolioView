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

  # Canadian venues, added by issue #66. The exchange NAMES are what
  # Directory::ImportCanadianJob stores (the MICs XTSE/XTSX/NEOE/XCNQ live in
  # SymbolQualifier, which maps them to the venue suffix).
  CANADIAN_EXCHANGES = [ "TSX", "TSXV", "NEO", "CSE" ].to_set.freeze

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

  # A row this app can actually turn into an Instrument. Anything else (NMFQS,
  # PINK, OTCGREY, a currency/venue mismatch) is un-addable: picking it in the
  # autocomplete only earns a 422 from DirectoryResolver, so it must never
  # outrank a row that works.
  #
  # Both halves of each pair matter. A USD row on the TSX, or a CAD row on
  # NASDAQ, is neither a US listing nor a Canadian one, and pricing it would
  # mean guessing which feed serves it — so it is not tradeable here (#66).
  #
  # ONE definition, used as a WHERE by #tradeable and as an ORDER BY expression
  # by #search. They must not drift, or a row could rank as tradeable while
  # resolving as un-tradeable; it is a SQL string rather than a scope because a
  # scope cannot be reused inside ORDER BY. Case-insensitive on both columns,
  # byte-equivalent to the Ruby predicate DirectoryResolver used to inline —
  # verified in #71 across all 105,445 distinct symbols, 23,434 rows both ways.
  # A Canadian row must ALSO be venue-suffixed. Directory::ImportCanadianJob
  # always stores them that way, and the suffix is what stops a Canadian ticker
  # binding to the US security of the same name: `instruments` is UNIQUE on
  # upper(symbol) alone, so a bare `SHOP` on the TSX and NYSE Shopify are the
  # same row. That collision is what #64's SymbolQualifier exists to prevent and
  # what a CDR makes dangerous — TSX `META` is a CAD-hedged fraction of the
  # underlying, not NASDAQ META. A bare symbol on a Canadian venue is therefore
  # ambiguous by construction and is not tradeable here.
  CANADIAN_SUFFIXES = %w[.TO .V .CN .NE].freeze

  TRADEABLE_SQL = <<~SQL.squish.freeze
    (upper(btrim(currency)) = 'USD' AND upper(btrim(exchange)) IN (:us))
    OR (upper(btrim(currency)) = 'CAD' AND upper(btrim(exchange)) IN (:ca)
        AND upper(btrim(symbol)) SIMILAR TO :ca_suffixed)
  SQL

  # Postgres SIMILAR TO: one alternation over the escaped suffixes.
  CANADIAN_SUFFIX_PATTERN = "%(#{CANADIAN_SUFFIXES.map { |s| s.sub('.', '\\.') }.join('|')})".freeze

  TRADEABLE_BINDS = {
    us: US_EXCHANGES.to_a,
    ca: CANADIAN_EXCHANGES.to_a,
    ca_suffixed: CANADIAN_SUFFIX_PATTERN
  }.freeze

  scope :tradeable, -> { where(TRADEABLE_SQL, **TRADEABLE_BINDS) }

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
  # Ranked on six tiers, in order (issues #63, #71). The match band alone was not
  # enough: the result set is capped at SEARCH_LIMIT, so with a purely
  # alphabetical tie-break a dense prefix silently truncates the one row the
  # user meant. Searching "MSF" returned MSF, MSFAX, MSFBX … MSFN and **MSFT
  # never appeared at all** — verified live against the real 106,362-row
  # directory.
  #
  #   1. match band     — exact symbol, then symbol prefix, then name-only
  #   2. tradeable      — rows DirectoryResolver would accept, before rows it
  #                       would reject with a 422
  #   3. live           — listings the provider still has recent prices for,
  #                       before delisted ones
  #   4. asset class    — ordinary equities/ETFs before mutual funds
  #   5. symbol length  — shorter tickers are the more prominent listing
  #   6. listing age    — older listings are the more established ones
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
  # Tier 6, listing age, makes SHORT queries work. It exists because an earlier
  # version of this comment claimed two-character queries "cannot be fixed"
  # without a popularity signal "the free directory does not carry" — which was
  # false. The signal was already in the table and simply unread: #63 added BOTH
  # `start_date` and `end_date` and ranked on `end_date` only (issue #71).
  #
  # **It sits AFTER length, and that order is load-bearing.** Age is a proxy for
  # prominence, so ranking on it before length systematically buries RECENT
  # listings behind old obscure ones: `ARMH`, a 1998 ADR that still carries
  # recent prices (so tier 3 counts it live), outranked the 2023 `ARM`, and
  # ARM/NET/RDDT/SOFI all fell out of the 2-character cap entirely.
  #
  # What makes THIS order safe is structural, not statistical: putting age after
  # length makes the ordering a strict REFINEMENT of the pre-#71 one — start_date
  # only breaks ties that were previously broken alphabetically, so no row can
  # cross a length boundary. Measured: 0 of 676 two-letter prefixes change their
  # top-20 length profile, against 376 of 676 for age-before-length.
  #
  # **THE COST, stated properly.** This is a trade, not a free win. Ranking by
  # age displaces symbols that used to make the cap on alphabetical luck:
  # exhaustively across all 676 two-letter prefixes, **~1,617 symbols** drop out
  # of a top-20 they previously reached — **1,219** of them live, `tradeable`
  # (as the scope above defines it), non-fund and <= 4 characters; 952 if you
  # additionally require a major venue, the ~267 difference being almost all
  # BATS. Named casualties include SNAP, MTCH, MBLY, ASAN, CELH, VICI and ARCC.
  # What that buys is the head of the distribution: AAPL, MSFT, AMZN, META,
  # TSLA, AVGO and COST become reachable at two characters for the first time.
  # **Every displaced symbol is still reachable at three characters** — verified
  # exhaustively, 1,617 of 1,617, median rank 3 — which is what makes the trade
  # defensible for an incremental type-ahead.
  #
  # Do NOT restate this as "loses only SOFI". An earlier version of this comment
  # did, measured from a 76-ticker list chosen by the same person who wrote the
  # tier; the real number is ~34x larger and only an exhaustive prefix sweep
  # finds it. A hand-picked ticker list will always flatter whoever picked it.
  #
  # Residual bias worth knowing: post-2020 rows hold 34.2% of top-20 slots here
  # versus 42.4% with no age tier at all (and 31.7% with age-before-length),
  # while 55.5% of live tradeable non-fund rows are post-2020. This still tilts
  # against recent listings — it recovers about a quarter of what the wrong
  # order gave away, not all of it.
  #
  # **Don't reorder these two tiers without re-running the exhaustive sweep** —
  # the intuitive order is the losing one, and a small sample will not show it.
  #
  # NULLs sort LAST so an unknown listing date never outranks a known one — the
  # opposite convention from tier 3, where a NULL `end_date` means "assume live"
  # so a parse gap cannot hide a ticker. (`ASC NULLS LAST` is also Postgres'
  # default for `ASC`, so deleting those two words changes nothing; they are
  # there to state the intent, and the tests pin the behaviour, not the syntax.)
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
        CASE WHEN #{TRADEABLE_SQL} THEN 0 ELSE 1 END,
        CASE WHEN end_date IS NULL OR end_date >= (CURRENT_DATE - :stale) THEN 0
             ELSE 1 END,
        CASE WHEN lower(asset_type) LIKE :fund THEN 1 ELSE 0 END,
        length(symbol),
        start_date ASC NULLS LAST
      SQL
        **TRADEABLE_BINDS,
        exact: q.upcase, prefix: symbol_prefix,
        stale: STALE_LISTING_WINDOW, fund: MUTUAL_FUND_PATTERN
      } ])))
      .order(:symbol, :exchange)
      .limit(limit)
  end
end
