require "test_helper"

# Autocomplete relevance ranking (issue #63).
#
# The bug these guard against is subtle because nothing errors: the result set
# is capped at SEARCH_LIMIT, so a badly-ranked query does not return a wrong
# row, it silently OMITS the right one. Every ordering test here therefore
# asserts on presence-within-the-cap, not just on relative position.
class ListedInstrumentSearchTest < ActiveSupport::TestCase
  # The real directory's MSF* neighbourhood, reproduced from a live query
  # against all 106,253 rows. MSFT is the 23rd symbol alphabetically, past the
  # 20-row cap — which is exactly why it used to vanish.
  def seed_msf_neighbourhood!
    %w[MSFAX MSFBX MSFDX MSFEX MSFFX MSFHX MSFIX MSFJX MSFKX MSFLX MSFRX MSFYX].each do |s|
      ListedInstrument.create!(symbol: s, exchange: "NMFQS", asset_type: "Mutual Fund", currency: "USD")
    end
    %w[MSFC MSFD MSFG MSFL MSFU].each do |s|
      ListedInstrument.create!(symbol: s, exchange: "NASDAQ", asset_type: "Stock", currency: "USD")
    end
    %w[MSFW MSFX MSFY].each do |s|
      ListedInstrument.create!(symbol: s, exchange: "BATS", asset_type: "ETF", currency: "USD")
    end
    ListedInstrument.create!(symbol: "MSFFS", exchange: "PINK", asset_type: "Stock", currency: "USD")
    ListedInstrument.create!(symbol: "MSFIW", exchange: "OTCGREY", asset_type: "Stock", currency: "USD")
    ListedInstrument.create!(symbol: "MSFJY", exchange: "OTCMKTS", asset_type: "Stock", currency: "USD")
    ListedInstrument.create!(symbol: "MSFN", exchange: "EXPM", asset_type: "Stock", currency: "USD")
    ListedInstrument.create!(symbol: "MSF", exchange: "NYSE", asset_type: "ETF", currency: "USD")
    ListedInstrument.create!(symbol: "MSFT", exchange: "NASDAQ", asset_type: "Stock", currency: "USD")
  end

  # --- the regression that opened the issue ---------------------------------

  test "MSFT is returned for 'MSF' — the dense mutual-fund prefix must not push it past the cap" do
    seed_msf_neighbourhood!

    results = ListedInstrument.search("MSF").map(&:symbol)

    assert_includes results, "MSFT",
      "MSFT fell outside the #{ListedInstrument::SEARCH_LIMIT}-row cap; this is issue #63 exactly"
    assert_equal "MSF", results.first, "the exact match still ranks first"
  end

  test "a tradeable equity outranks every mutual fund and every untradeable venue" do
    seed_msf_neighbourhood!

    results = ListedInstrument.search("MSF").map(&:symbol)
    msft = results.index("MSFT")

    %w[MSFAX MSFBX MSFYX].each do |fund|
      assert msft < results.index(fund), "MSFT must outrank the mutual fund #{fund}" if results.index(fund)
    end
    %w[MSFFS MSFIW MSFJY MSFN].each do |untradeable|
      if results.index(untradeable)
        assert msft < results.index(untradeable), "MSFT must outrank #{untradeable} (untradeable venue)"
      end
    end
  end

  # --- the individual ranking tiers -----------------------------------------

  test "an exact symbol match ranks first even when it is a mutual fund on an untradeable venue" do
    ListedInstrument.create!(symbol: "ZZTOP", exchange: "NMFQS", asset_type: "Mutual Fund", currency: "USD")
    ListedInstrument.create!(symbol: "ZZTOPA", exchange: "NASDAQ", asset_type: "Stock", currency: "USD")

    # The user typed the whole ticker; that intent outranks every other signal.
    assert_equal "ZZTOP", ListedInstrument.search("ZZTOP").first.symbol
  end

  test "a tradeable row outranks an untradeable one at the same match band" do
    ListedInstrument.create!(symbol: "QQAB", exchange: "OTCGREY", asset_type: "Stock", currency: "USD")
    ListedInstrument.create!(symbol: "QQAC", exchange: "NYSE",    asset_type: "Stock", currency: "USD")

    # Alphabetically QQAB wins; it must still lose, because picking it only
    # earns a 422 from DirectoryResolver.
    assert_equal %w[QQAC QQAB], ListedInstrument.search("QQA").map(&:symbol)
  end

  # #search spells the tradeable predicate inline (it is an ORDER BY expression
  # and cannot reuse the scope), and the model comment requires the two
  # spellings to stay identical — `upper(btrim(...))` on BOTH columns. Nothing
  # enforced that until this test: dropping `btrim` from #search leaves a padded
  # row ranking as untradeable while DirectoryResolver happily resolves it.
  test "a padded currency/exchange ranks tradeable, matching what the resolver accepts" do
    ListedInstrument.create!(symbol: "QQAB", exchange: "OTCGREY", asset_type: "Stock", currency: "USD")
    ListedInstrument.create!(symbol: "QQAC", exchange: " NYSE ", asset_type: "Stock", currency: " usd ")

    assert_equal %w[QQAC QQAB], ListedInstrument.search("QQA").map(&:symbol),
      "the padded row is resolvable, so it must not rank below an untradeable one"
    assert Instruments::DirectoryResolver.call(symbol: "QQAC").ok?,
      "sanity: the resolver and #search must agree on this row"
  end

  test "a non-USD row is treated as untradeable and demoted" do
    ListedInstrument.create!(symbol: "QQAB", exchange: "NYSE", asset_type: "Stock", currency: "CAD")
    ListedInstrument.create!(symbol: "QQAC", exchange: "NYSE", asset_type: "Stock", currency: "USD")

    assert_equal %w[QQAC QQAB], ListedInstrument.search("QQA").map(&:symbol)
  end

  test "an equity outranks a mutual fund on the same tradeable exchange" do
    ListedInstrument.create!(symbol: "QQAB", exchange: "NASDAQ", asset_type: "Mutual Fund", currency: "USD")
    ListedInstrument.create!(symbol: "QQAC", exchange: "NASDAQ", asset_type: "Stock", currency: "USD")

    assert_equal %w[QQAC QQAB], ListedInstrument.search("QQA").map(&:symbol)
  end

  # --- the liveness tier, and the second regression it was added for ---------

  # `search("AA")` returned 20 rows without AAPL even after the first four
  # tiers: 50 tradeable non-fund 4-char AA* rows compete for 20 slots, and
  # AAPL is alphabetically ~30th among them. Nothing else stored separates it
  # from AABA (Altaba, liquidated 2019) — both NASDAQ/Stock/USD.
  test "a live ticker outranks 50 dead alphabetical peers that would fill the cap" do
    live = Date.current - 2
    dead = Date.current - 6.years
    # Every delisted AA* row sorts alphabetically before AAPL, as in the real file.
    %w[AAAA AAAC AAAD AAAP AAAU AABA AACB AACC AACG AACI AACO AACP AACT AADR
       AADX AAEQ AAGR AAIC AAIN AAIT AALG AAME AAMI AAOG].each do |s|
      ListedInstrument.create!(symbol: s, exchange: "NASDAQ", asset_type: "Stock",
                               currency: "USD", end_date: dead)
    end
    ListedInstrument.create!(symbol: "AAPL", exchange: "NASDAQ", asset_type: "Stock",
                             currency: "USD", end_date: live)

    results = ListedInstrument.search("AA").map(&:symbol)

    assert_includes results, "AAPL",
      "AAPL fell outside the #{ListedInstrument::SEARCH_LIMIT}-row cap behind delisted tickers"
    assert_equal "AAPL", results.first, "the only live listing should lead"
  end

  test "a delisted listing ranks below a live one at the same match band" do
    ListedInstrument.create!(symbol: "QQAB", exchange: "NYSE", asset_type: "Stock",
                             currency: "USD", end_date: Date.current - 6.years)
    ListedInstrument.create!(symbol: "QQAC", exchange: "NYSE", asset_type: "Stock",
                             currency: "USD", end_date: Date.current - 2)

    assert_equal %w[QQAC QQAB], ListedInstrument.search("QQA").map(&:symbol)
  end

  test "a NULL end_date ranks as live, so a parse gap can never hide a real ticker" do
    ListedInstrument.create!(symbol: "QQAB", exchange: "NYSE", asset_type: "Stock",
                             currency: "USD", end_date: Date.current - 6.years)
    ListedInstrument.create!(symbol: "QQAC", exchange: "NYSE", asset_type: "Stock",
                             currency: "USD", end_date: nil)

    assert_equal %w[QQAC QQAB], ListedInstrument.search("QQA").map(&:symbol)
  end

  test "liveness outranks asset class — a live fund beats a delisted equity" do
    ListedInstrument.create!(symbol: "QQAB", exchange: "NASDAQ", asset_type: "Stock",
                             currency: "USD", end_date: Date.current - 6.years)
    ListedInstrument.create!(symbol: "QQAC", exchange: "NASDAQ", asset_type: "Mutual Fund",
                             currency: "USD", end_date: Date.current - 2)

    assert_equal %w[QQAC QQAB], ListedInstrument.search("QQA").map(&:symbol)
  end

  test "an exact match still wins even when the listing is dead" do
    ListedInstrument.create!(symbol: "QQAB", exchange: "NYSE", asset_type: "Stock",
                             currency: "USD", end_date: Date.current - 6.years)
    ListedInstrument.create!(symbol: "QQABC", exchange: "NYSE", asset_type: "Stock",
                             currency: "USD", end_date: Date.current - 2)

    assert_equal "QQAB", ListedInstrument.search("QQAB").first.symbol
  end

  # --- listing age (issue #71) ----------------------------------------------

  test "an older listing outranks a newer one once the other tiers tie" do
    ListedInstrument.create!(symbol: "QQAB", exchange: "NYSE", asset_type: "Stock",
                             currency: "USD", start_date: Date.new(2021, 1, 1))
    ListedInstrument.create!(symbol: "QQAC", exchange: "NYSE", asset_type: "Stock",
                             currency: "USD", start_date: Date.new(1980, 12, 12))

    # Alphabetically QQAB wins; the older listing must still lead.
    assert_equal %w[QQAC QQAB], ListedInstrument.search("QQA").map(&:symbol)
  end

  # The inverse of the tier order, pinned deliberately: LENGTH outranks AGE.
  # The opposite (age first) is the intuitive choice and is measurably worse —
  # it buries recent listings behind old obscure ones. See the tier comment in
  # ListedInstrument for the measurement.
  test "symbol length outranks listing age — a new short ticker beats an old long one" do
    ListedInstrument.create!(symbol: "QQAB", exchange: "NYSE", asset_type: "Stock",
                             currency: "USD", start_date: Date.new(2024, 1, 1))
    ListedInstrument.create!(symbol: "QQABCD", exchange: "NYSE", asset_type: "Stock",
                             currency: "USD", start_date: Date.new(1980, 12, 12))

    assert_equal %w[QQAB QQABCD], ListedInstrument.search("QQA").map(&:symbol)
  end

  test "a NULL start_date sorts LAST, so an unknown date never outranks a known one" do
    ListedInstrument.create!(symbol: "QQAB", exchange: "NYSE", asset_type: "Stock",
                             currency: "USD", start_date: nil)
    ListedInstrument.create!(symbol: "QQAC", exchange: "NYSE", asset_type: "Stock",
                             currency: "USD", start_date: Date.new(2024, 6, 1))

    # The opposite convention from end_date, where NULL means "assume live".
    assert_equal %w[QQAC QQAB], ListedInstrument.search("QQA").map(&:symbol)
  end

  # Every peer is the SAME LENGTH as the target, so the length tier cannot
  # discriminate and only listing age can. The first version of this test seeded
  # 5-character peers against a 4-character target, which meant it passed with
  # the age tier deleted entirely — vacuous w.r.t. the tier it names.
  test "a long-established ticker survives the cap behind 25 same-length newer peers" do
    25.times do |i|
      ListedInstrument.create!(symbol: format("QQA%02d", i), exchange: "NYSE", asset_type: "Stock",
                               currency: "USD", start_date: Date.new(2023, 1, 1))
    end
    ListedInstrument.create!(symbol: "QQZ99", exchange: "NYSE", asset_type: "Stock",
                             currency: "USD", start_date: Date.new(1980, 12, 12))

    results = ListedInstrument.search("QQ").map(&:symbol)

    assert_equal "QQZ99", results.first,
      "the oldest listing must lead once length ties; alphabetically it sorts last"
    assert_equal ListedInstrument::SEARCH_LIMIT, results.size
  end

  # The regression that failed #71's first gate: ranking on age alone buried
  # recent listings behind old obscure ones (ARM, NET, RDDT, SOFI all fell out
  # of the cap). Length must outrank age so a short recent ticker beats a long
  # old one.
  test "a SHORT recent listing outranks a LONGER old one — age must not dominate length" do
    ListedInstrument.create!(symbol: "ARMH", exchange: "NYSE", asset_type: "Stock",
                             currency: "USD", start_date: Date.new(1998, 4, 17),
                             end_date: Date.current - 2)
    ListedInstrument.create!(symbol: "ARM", exchange: "NASDAQ", asset_type: "Stock",
                             currency: "USD", start_date: Date.new(2023, 9, 14),
                             end_date: Date.current - 1)

    assert_equal %w[ARM ARMH], ListedInstrument.search("AR").map(&:symbol),
      "the 2023 ARM must beat the 1998 ARMH; reordering age above length reverses this"
  end

  test "25 old long peers cannot crowd a short recent listing out of the cap" do
    25.times do |i|
      ListedInstrument.create!(symbol: format("ARA%02d", i), exchange: "NYSE", asset_type: "Stock",
                               currency: "USD", start_date: Date.new(1985, 1, 1))
    end
    ListedInstrument.create!(symbol: "ARM", exchange: "NASDAQ", asset_type: "Stock",
                             currency: "USD", start_date: Date.new(2023, 9, 14))

    assert_equal "ARM", ListedInstrument.search("AR").map(&:symbol).first
  end

  test "liveness still outranks listing age — an old delisted ticker loses to a new live one" do
    ListedInstrument.create!(symbol: "QQAB", exchange: "NYSE", asset_type: "Stock", currency: "USD",
                             start_date: Date.new(1980, 12, 12), end_date: Date.current - 6.years)
    ListedInstrument.create!(symbol: "QQAC", exchange: "NYSE", asset_type: "Stock", currency: "USD",
                             start_date: Date.new(2024, 1, 1), end_date: Date.current - 2)

    assert_equal %w[QQAC QQAB], ListedInstrument.search("QQA").map(&:symbol)
  end

  test "a shorter symbol outranks a longer one once the other tiers tie" do
    ListedInstrument.create!(symbol: "QQAAA", exchange: "NYSE", asset_type: "Stock", currency: "USD")
    ListedInstrument.create!(symbol: "QQAB",  exchange: "NYSE", asset_type: "Stock", currency: "USD")

    assert_equal %w[QQAB QQAAA], ListedInstrument.search("QQA").map(&:symbol)
  end

  test "ordering is total, so equal-ranked rows come back in a deterministic order" do
    ListedInstrument.create!(symbol: "QQAB", exchange: "NYSE",   asset_type: "Stock", currency: "USD")
    ListedInstrument.create!(symbol: "QQAB", exchange: "NASDAQ", asset_type: "Stock", currency: "USD")

    assert_equal %w[NASDAQ NYSE], ListedInstrument.search("QQAB").map(&:exchange)
  end

  # --- name matching (the point of enriching names at all) -------------------

  test "rows with an enriched name match on name, and still rank below symbol matches" do
    ListedInstrument.create!(symbol: "MSFT", exchange: "NASDAQ", asset_type: "Stock",
                             currency: "USD", name: "Microsoft Corporation")
    ListedInstrument.create!(symbol: "MICR", exchange: "NASDAQ", asset_type: "Stock",
                             currency: "USD", name: "Micron Something")

    results = ListedInstrument.search("Micro").map(&:symbol)

    assert_includes results, "MSFT", "a name match must be findable"
    assert_equal "MICR", results.first, "the symbol-prefix match outranks the name-only match"
  end

  test "search still works when every name is null — the pre-enrichment state" do
    ListedInstrument.create!(symbol: "AAPL", exchange: "NASDAQ", asset_type: "Stock",
                             currency: "USD", name: nil)

    assert_equal [ "AAPL" ], ListedInstrument.search("AAPL").map(&:symbol)
    assert_equal [], ListedInstrument.search("Apple Inc").map(&:symbol)
  end

  # --- preserved behaviour from #026 ----------------------------------------

  test "LIKE metacharacters stay literal so a query cannot wildcard the directory" do
    ListedInstrument.create!(symbol: "AAPL", exchange: "NASDAQ", asset_type: "Stock", currency: "USD")

    assert_equal [], ListedInstrument.search("A%").map(&:symbol)
  end

  test "the result set stays bounded by SEARCH_LIMIT" do
    30.times { |i| ListedInstrument.create!(symbol: "QQA#{i}", exchange: "NYSE", asset_type: "Stock", currency: "USD") }

    assert_equal ListedInstrument::SEARCH_LIMIT, ListedInstrument.search("QQA").size
  end

  test "a blank query returns nothing rather than the whole directory" do
    ListedInstrument.create!(symbol: "AAPL", exchange: "NASDAQ", asset_type: "Stock", currency: "USD")

    assert_equal [], ListedInstrument.search("").to_a
    assert_equal [], ListedInstrument.search("   ").to_a
  end
end
