require "test_helper"

# Stubbed-HTTP unit tests for the Yahoo EOD adapter (issue #66). All requests
# hit the Faraday :test adapter with recorded fixture bodies (testing-conventions:
# mock at the Faraday boundary) — no test ever touches the real Yahoo endpoint.
#
# The fixtures below are trimmed from REAL responses.
#
# ONE CORRECTION TO WHAT THIS COMMENT USED TO SAY (issue #66's round-3 gate,
# Finding 4). It claimed the AAPL case was "a cross-source agreement, not this
# adapter agreeing with itself", pointing at Tiingo-sourced fixtures in this repo.
# There are none — `test/fixtures/files/` holds only the two broker CSVs and the
# SPA index — and the input below is literally `124.81 / 4.0` with `124.81`
# asserted back, so the arithmetic is exercised but the number is Yahoo's own
# adjusted close, not an independent raw one. The real cross-source check exists
# and is worth keeping: run live, Yahoo's un-adjusted AAPL agrees with Tiingo's
# raw closes to 0.000012 across the 2020 4:1 over 11,499 overlapping days. That
# cannot live in a hermetic unit test, so it belongs in a gate, not here.
class PriceProvider::YahooTest < ActiveSupport::TestCase
  # 13:30 UTC is 09:30 America/New_York — the session open, which is how Yahoo
  # timestamps a daily bar.
  def ts(date, hour_utc = 13, min = 30)
    Time.utc(date.year, date.month, date.day, hour_utc, min).to_i
  end

  # gmtoffset for America/New_York in August (EDT, UTC-4).
  US_OFFSET = -4 * 3600

  def chart(timestamps:, quote:, splits: {}, dividends: {}, offset: US_OFFSET, currency: "USD")
    {
      "chart" => {
        "error" => nil,
        "result" => [ {
          "meta" => { "currency" => currency, "exchangeName" => "NMS", "gmtoffset" => offset },
          "timestamp" => timestamps,
          "events" => { "splits" => splits, "dividends" => dividends }.compact,
          "indicators" => { "quote" => [ quote ] }
        } ]
      }
    }.to_json
  end

  def build_adapter(stubs)
    PriceProvider::Yahoo.new(faraday_adapter: [ :test, stubs ])
  end

  # Builds a two-bar series around one factor: a close on the session BEFORE the
  # ex-date and a close ON it, which is exactly the pair #adjusted_gap reads.
  def classify_factor(symbol:, ex_date:, num:, den:, before_close:, after_close:)
    before = ex_date - 1
    body = chart(
      timestamps: [ ts(before), ts(ex_date) ],
      quote: { "open" => [ before_close, after_close ], "high" => [ before_close, after_close ],
               "low" => [ before_close, after_close ], "close" => [ before_close, after_close ],
               "volume" => [ 1, 1 ] },
      splits: { "f" => { "date" => ts(ex_date), "numerator" => num, "denominator" => den } }
    )
    build_adapter(stub_chart(symbol, body)).fetch_daily(symbol, from: before, to: ex_date)
  end

  def stub_chart(symbol, body, status: 200)
    stubs = Faraday::Adapter::Test::Stubs.new
    stubs.get("/v8/finance/chart/#{symbol}") { [ status, { "Content-Type" => "application/json" }, body ] }
    stubs
  end

  # --- the reason this adapter is not a thin JSON mapper ---------------------

  # Yahoo's OHLC is SPLIT-ADJUSTED; this app stores RAW and applies splits at
  # read time. Storing Yahoo's numbers unchanged would apply every split twice.
  # The adjusted closes here are Yahoo's real August-2020 AAPL values; the
  # expected raw closes are the real unadjusted ones.
  test "un-adjusts split-adjusted prices back to raw, so splits are not applied twice" do
    dates = [ Date.new(2020, 8, 28), Date.new(2020, 8, 31) ]
    body = chart(
      timestamps: dates.map { |d| ts(d) },
      quote: { "open" => [ 31.4525, 127.58 ], "high" => [ 31.61, 131.0 ],
               "low" => [ 31.145, 126.0 ], "close" => [ 124.81 / 4.0, 129.04 ],
               "volume" => [ 187_630_000, 225_702_000 ] },
      splits: { "1598880600" => { "date" => ts(Date.new(2020, 8, 31)),
                                  "numerator" => 4.0, "denominator" => 1.0, "splitRatio" => "4:1" } }
    )

    series = build_adapter(stub_chart("AAPL", body)).fetch_daily("AAPL", from: dates.first, to: dates.last)

    pre, post = series.bars
    # The 4:1 has ex_date 2020-08-31, so the 08-28 bar is BEFORE it and must be
    # scaled back up; the ex-date bar itself is already in post-split terms.
    assert_equal BigDecimal("124.81"), pre.close, "pre-split close must be reconstructed as raw"
    assert_equal BigDecimal("129.04"), post.close, "the ex-date bar must NOT be scaled"
    assert_equal [ BigDecimal("4.0") ], series.splits.map(&:ratio)
  end

  test "a split ON the bar's date does not scale that bar — the ex-date boundary" do
    d = Date.new(2020, 8, 31)
    body = chart(
      timestamps: [ ts(d) ],
      quote: { "open" => [ 127.58 ], "high" => [ 131.0 ], "low" => [ 126.0 ],
               "close" => [ 129.04 ], "volume" => [ 1 ] },
      splits: { "x" => { "date" => ts(d), "numerator" => 4.0, "denominator" => 1.0 } }
    )

    bar = build_adapter(stub_chart("AAPL", body)).fetch_daily("AAPL", from: d, to: d).bars.first

    assert_equal BigDecimal("129.04"), bar.close,
      "Holdings::Calculator applies a split at the START of its ex-date; double-scaling here would fight it"
  end

  # --- classifying a factor: share-count event, or price-only? ---------------
  #
  # THE TABLE BELOW IS THE REGRESSION SUITE FOR THREE REJECTED GATE ROUNDS. Every
  # row is a real security with real numbers taken from the live Yahoo feed —
  # including the ADJUSTED CLOSES either side of the ex-date, because those are the
  # evidence the classifier actually uses (see Yahoo#classify_splits). A row's
  # `gap` is what the feed really showed, not a number chosen to make the rule
  # work.
  #
  # The two rows that matter most are `XCS.TO 9:10` and `FTN.TO 11:10`. Their
  # written forms are indistinguishable — both a small integer over 10, both near
  # 1 — and their truths are opposite. No rule reading (num, den) can separate
  # them, and round 4's gate showed the PRICE SERIES cannot either: a
  # consolidation paired with a cash return looks exactly like a distribution.
  # So both rows are now price-only, one correctly and one at a known cost, and
  # this table records which is which. `expected` here is simply whether the
  # ratio falls outside NEAR_ONE_BAND.
  FACTOR_CASES = [
    # symbol, ex-date, num, den, close before, close on, expected, why
    [ "XCS.TO",  "2021-12-30",     9.0,      10.0, 111.22, 100.0, :price_only,
      "round 3 Finding 1: iShares' year-end reinvested distribution. Kept as a split " \
      "it destroyed 10% of the position. gap 1.1122 matches 1/ratio 1.1111 almost " \
      "exactly: the traded price never moved" ],
    [ "XCS.TO",  "2025-12-30",    96.0,     100.0, 104.17, 100.0, :price_only,
      "the SAME fund's SAME annual action, four years later. Round 3 classified this " \
      "one correctly and 9:10 wrongly — one fund, one action, two verdicts" ],
    [ "FTN.TO",  "2025-09-26",    11.0,      10.0,  96.93, 100.0, :price_only,
      "a genuine 11-for-10 subdivision. Same written shape as XCS.TO 9:10 and the " \
      "opposite truth; gap 0.9693 sits at 1, not at 1/ratio 0.9091" ],
    [ "LCS.TO",  "2024-12-17",   114.0,     100.0,  99.59, 100.0, :price_only,
      "round 3 called LCS.TO split-brained: 114:100 and 112:100 suppressed while the " \
      "same fund's 6:5 was kept. All three are share-count events and now agree" ],
    [ "LCS.TO",  "2026-01-27",     6.0,       5.0, 102.14, 100.0, :price_only,
      "the third LCS.TO factor, and the one round 3 already kept" ],
    [ "TRP.TO",  "2024-10-02",  1097.0,    1000.0, 100.15, 100.0, :price_only,
      "round 1 blocker: the South Bow spin-off. +9.7% phantom shares if kept. NOTE the " \
      "gap says 'the price moved' (1.0015) and is CORRECT to — a spin-off really does " \
      "move the parent's price — so the market-derived denominator has to win here" ],
    [ "BN.TO",   "2022-12-12",  1237.0,    1000.0, 103.27, 100.0, :price_only,
      "round 1 blocker: the BAM spin-off, +23.7% phantom shares" ],
    [ "BN.TO",   "2013-04-15",  1033.0,    1000.0, 100.98, 100.0, :price_only,
      "the same corporate action at a different size — round 1 classified these two " \
      "BN.TO spin-offs OPPOSITE ways purely by magnitude" ],
    [ "ZEQT.TO", "2025-12-30",   993.0,    1000.0, 101.10, 100.0, :price_only,
      "the distribution #68's ledger proved does not move units: it reconciled 13 of " \
      "14 positions on the 3:1 alone" ],
    [ "VDY.TO",  "2025-12-30",   987.0,    1000.0, 101.38, 100.0, :price_only, "same family" ],
    [ "HMMC.TO", "2023-01-04",     1.0,     300.0, 100.00, 100.0, :share_count,
      "round 2 blocker: a 1-for-300 consolidation on a fund the user holds. Suppressed, " \
      "a backdated buy reported CAD 1,230 against a true CAD 4.10" ],
    [ "VTI.CN",  "2026-05-22",     1.0,     100.0, 200.00, 100.0, :share_count,
      "round 2 blocker, and ALSO the Yahoo data-quality case: gap 2.0 would read as " \
      "'price-only' on the series alone. The band guard is what stops a 100x error" ],
    [ "RAGE.V",  "2023-07-17",     1.0,      10.0, 1000.0, 100.0, :share_count,
      "the same data-quality shape on a thin TSXV listing: the feed did not adjust its " \
      "own factor, so gap is exactly 1/ratio. Still a consolidation" ],
    [ "LUG.TO",  "1997-11-03",   100.0,     270.0, 100.29, 100.0, :share_count,
      "round 3 Finding 2: a 1-for-2.7 consolidation, suppressed because its numerator " \
      "was not 1" ],
    [ "WCN.TO",  "2016-06-01",  4815.0,   10000.0,  97.65, 100.0, :share_count,
      "round 3 Finding 2: a merger consolidation. Its denominator is 2000 in lowest " \
      "terms, so only the band guard keeps it — a market-derived-looking ratio can " \
      "still be a real share-count change when it is nowhere near 1" ],
    [ "WKHS",    "2025-03-17",     8.0,     100.0, 128.08, 100.0, :share_count,
      "round 3 Finding 2: a real 1-for-12.5 reverse split, dropped because 12.5 is not " \
      "an integer" ],
    [ "GOOG",    "2014-03-27",  2002.0,    1000.0, 101.25, 100.0, :share_count,
      "round 3 Finding 2: the Class C split, written unreduced" ],
    [ "AAPL",    "2020-08-31",     4.0,       1.0,  96.72, 100.0, :share_count,
      "the ordinary case, and the control: an unambiguous 4:1" ],
    [ "GE",      "2021-08-02",     1.0,       8.0, 102.98, 100.0, :share_count,
      "an ordinary reverse split" ]
  ].freeze

  test "every factor the three rejected gate rounds named is classified correctly" do
    FACTOR_CASES.each do |symbol, ex_date, num, den, before_close, after_close, expected, why|
      series = classify_factor(symbol:, ex_date: Date.parse(ex_date), num:, den:,
                               before_close:, after_close:)
      actual = series.splits.any? ? :share_count : :price_only

      assert_equal expected, actual,
        "#{symbol} #{ex_date} #{num.to_i}:#{den.to_i} should be #{expected} — #{why}"
    end
  end

  test "a price-only factor still un-adjusts the price, and says so out loud" do
    # The half a suppression must not throw away: Yahoo's pre-ex-date closes were
    # divided by the factor, so dropping it outright leaves the whole earlier
    # history off by it.
    series = classify_factor(symbol: "ZEQT.TO", ex_date: Date.new(2025, 12, 30),
                             num: 993.0, den: 1000.0, before_close: 1000.0, after_close: 20.51)

    assert_empty series.splits
    assert_equal BigDecimal("993"), series.bars.first.close,
      "the PRICE must still be un-adjusted by it, or history sits 0.7% low"
    assert(series.warnings.any? { |w| w.include?("price-only") && w.include?("993:1000") },
      "a reclassification must name the factor and be visible, not silent")
  end

  test "the warning does not claim to know WHICH price-only action it was" do
    # It cannot: a reinvested distribution and a spin-off are the same shape here,
    # and an earlier version of this file asserted the wording "reinvested
    # distribution" for both. Naming one specifically is an overclaim.
    series = classify_factor(symbol: "TRP.TO", ex_date: Date.new(2024, 10, 2),
                             num: 1097.0, den: 1000.0, before_close: 100.15, after_close: 100.0)

    warning = series.warnings.find { |w| w.include?("price-only") }
    assert warning
    assert_match(/distribution or a spin-off/, warning)
  end

  test "an in-band factor is price-only even with no earlier bar to judge it by" do
    # Used to be the "no bar on one side" fallback, which kept it as a share-count
    # event on the strength of the written form. 21:20 is a real 5% stock dividend
    # and IS now missed — the known cost. It is also the inconsequential case: with
    # no earlier bar there is no price for the factor to un-adjust either way.
    d = Date.new(2024, 6, 3)
    body = chart(
      timestamps: [ ts(d) ],
      quote: { "open" => [ 10.0 ], "high" => [ 10.0 ], "low" => [ 10.0 ], "close" => [ 10.0 ], "volume" => [ 1 ] },
      splits: { "z" => { "date" => ts(d), "numerator" => 21.0, "denominator" => 20.0 } }
    )

    series = build_adapter(stub_chart("XYZ", body)).fetch_daily("XYZ", from: d, to: d)

    assert_empty series.splits
    assert(series.warnings.any? { |w| w.include?("21:20") && w.include?("share count is left alone") })
  end

  test "the in-band warning tells the user how to supply the split themselves" do
    # A suppression that may be wrong has to be actionable, not just disclosed.
    series = classify_factor(symbol: "FTN.TO", ex_date: Date.new(2025, 9, 26),
                             num: 11.0, den: 10.0, before_close: 96.93, after_close: 100.0)

    warning = series.warnings.find { |w| w.include?("11:10") }
    assert warning
    assert_match(/activity ledger/, warning, "name the source that does know")
  end

  test "Factor#label quotes the fraction as Yahoo wrote it, fractions included" do
    # It used to truncate with .to_i on the belief that these are always whole
    # numbers. Yahoo sends 1.0697:1 (BHP Steel demerger) and 0.9876:1, which
    # printed as "1:1" and "0:1" — making the only warning naming them misleading.
    whole = PriceProvider::Factor.new(ex_date: Date.new(2024, 1, 1), ratio: BigDecimal("4"),
                                      numerator: BigDecimal("4"), denominator: BigDecimal("1"))
    assert_equal "4:1", whole.label, "a whole number must not read as 4.0:1.0"

    unreduced = PriceProvider::Factor.new(ex_date: Date.new(2024, 1, 1), ratio: BigDecimal("1.14"),
                                          numerator: BigDecimal("114"), denominator: BigDecimal("100"))
    assert_equal "114:100", unreduced.label, "quote the feed, not a reduction"

    fractional = PriceProvider::Factor.new(ex_date: Date.new(2002, 7, 2), ratio: BigDecimal("1.0697"),
                                           numerator: BigDecimal("1.0697"), denominator: BigDecimal("1"))
    assert_equal "1.0697:1", fractional.label, "measured live on BHP.AX; it used to print 1:1"
  end

  test "ONE corporate action reported on two nearby ex-dates becomes ONE split" do
    # Measured live: VTI.CN reports 1:100 on both 2026-05-22 and 2026-05-27 for a
    # single 1-for-100, and split_events upserts on [instrument_id, ex_date] — so
    # two rows persisted and Holdings::Calculator divided by 10,000. AMC.AX does
    # the same with 1:5 on 01-13 and 01-15 (25x).
    d1, d2 = Date.new(2026, 5, 22), Date.new(2026, 5, 27)
    body = chart(
      timestamps: [ ts(Date.new(2026, 5, 21)), ts(d2) ],
      quote: { "open" => [ 1.0, 100.0 ], "high" => [ 1.0, 100.0 ], "low" => [ 1.0, 100.0 ],
               "close" => [ 1.0, 100.0 ], "volume" => [ 1, 1 ] },
      splits: { "a" => { "date" => ts(d1), "numerator" => 1.0, "denominator" => 100.0 },
                "b" => { "date" => ts(d2), "numerator" => 1.0, "denominator" => 100.0 } }
    )

    series = build_adapter(stub_chart("VTI.CN", body)).fetch_daily("VTI.CN", from: Date.new(2026, 5, 1))

    assert_equal 1, series.splits.size, "two reports of one action must not compound"
    assert_equal d1, series.splits.first.ex_date, "the EARLIER date is kept"
    assert(series.warnings.any? { |w| w.include?("ONE corporate action") })
  end

  test "the same ratio far apart is NOT collapsed — that is a second real action" do
    # BHP.AX really does carry 110:100 twice, six years apart.
    d1, d2 = Date.new(1989, 4, 21), Date.new(1995, 5, 11)
    body = chart(
      timestamps: [ ts(Date.new(1989, 4, 20)), ts(d2) ],
      quote: { "open" => [ 10.0, 10.0 ], "high" => [ 10.0, 10.0 ], "low" => [ 10.0, 10.0 ],
               "close" => [ 10.0, 10.0 ], "volume" => [ 1, 1 ] },
      splits: { "a" => { "date" => ts(d1), "numerator" => 3.0, "denominator" => 1.0 },
                "b" => { "date" => ts(d2), "numerator" => 3.0, "denominator" => 1.0 } }
    )

    series = build_adapter(stub_chart("BHP.AX", body)).fetch_daily("BHP.AX", from: Date.new(1989, 1, 1))

    assert_equal 2, series.splits.size
  end

  test "classification reads YAHOO'S adjusted closes, not the reconstructed ones" do
    # The ordering fact in #build_series. If classification ran after #unadjust!,
    # the gap would be measured on a series from which this very factor had already
    # been divided out — evidence about the factor derived from the factor. This
    # case pins it: on Yahoo's adjusted series the gap is 1.1122 (price-only), but
    # after un-adjustment the earlier close becomes 111.22 * 0.9 = 100.098 and the
    # gap collapses to ~1.0, which reads as a share-count event.
    series = classify_factor(symbol: "XCS.TO", ex_date: Date.new(2021, 12, 30),
                             num: 9.0, den: 10.0, before_close: 111.22, after_close: 100.0)

    assert_empty series.splits, "measured on the reconstructed series this would flip to a split"
    assert_in_delta 100.098, series.bars.first.close.to_f, 0.001,
      "and the reconstruction itself is unchanged by the classification"
  end

  # --- shape, robustness, and the keyless contract ---------------------------

  test "requires no API key, unlike every other adapter" do
    original = ENV.delete("TIINGO_API_KEY")
    assert_nothing_raised { build_adapter(stub_chart("AAPL", chart(timestamps: [], quote: {}))) }
    assert_raises(PriceProvider::ConfigurationError) { PriceProvider::Tiingo.new }
  ensure
    ENV["TIINGO_API_KEY"] = original if original
  end

  test "null-padded holidays and halts are skipped silently, not warned about" do
    dates = [ Date.new(2026, 7, 1), Date.new(2026, 7, 2) ]
    body = chart(
      timestamps: dates.map { |d| ts(d) },
      quote: { "open" => [ nil, 10.0 ], "high" => [ nil, 11.0 ], "low" => [ nil, 9.0 ],
               "close" => [ nil, 10.5 ], "volume" => [ nil, 100 ] }
    )

    series = build_adapter(stub_chart("AAPL", body)).fetch_daily("AAPL", from: dates.first, to: dates.last)

    assert_equal 1, series.bars.size
    assert_empty series.warnings, "a padded non-trading day is expected, not a data problem"
  end

  test "a partially bad row is skipped WITH a warning" do
    d = Date.new(2026, 7, 2)
    body = chart(
      timestamps: [ ts(d) ],
      quote: { "open" => [ 10.0 ], "high" => [ 1.0 ], "low" => [ 9.0 ], "close" => [ 10.5 ], "volume" => [ 1 ] }
    )

    series = build_adapter(stub_chart("AAPL", body)).fetch_daily("AAPL", from: d, to: d)

    assert_empty series.bars, "high < low violates the daily_prices CHECK and must never reach the upsert"
    assert_equal 1, series.warnings.size
  end

  # Yahoo answers HTTP 200 with a null result for an unknown symbol, so
  # Base#handle_status! never sees it.
  test "an unknown symbol is UnknownSymbol even though Yahoo answers HTTP 200" do
    body = { "chart" => { "result" => nil,
                          "error" => { "code" => "Not Found", "description" => "No data found" } } }.to_json

    assert_raises(PriceProvider::UnknownSymbol) do
      build_adapter(stub_chart("NOPE", body)).fetch_daily("NOPE", from: Date.new(2026, 7, 1))
    end
  end

  test "429 still maps to RateLimited through the shared base" do
    stubs = stub_chart("AAPL", "{}", status: 429)

    assert_raises(PriceProvider::RateLimited) do
      build_adapter(stubs).fetch_daily("AAPL", from: Date.new(2026, 7, 1))
    end
  end

  # Yahoo timestamps the session OPEN in UTC epoch. Reading that as a UTC date
  # would put an exchange east of UTC on the previous day.
  test "bars are keyed by the exchange's local date, not UTC" do
    # 23:00 UTC on the 1st is 09:00 on the 2nd in Sydney (UTC+10).
    body = chart(
      timestamps: [ Time.utc(2026, 7, 1, 23, 0).to_i ],
      quote: { "open" => [ 10.0 ], "high" => [ 11.0 ], "low" => [ 9.0 ], "close" => [ 10.5 ], "volume" => [ 1 ] },
      offset: 10 * 3600
    )

    bar = build_adapter(stub_chart("XYZ.AX", body)).fetch_daily("XYZ.AX", from: Date.new(2026, 7, 1)).bars.first

    assert_equal Date.new(2026, 7, 2), bar.date
  end

  test "dividends are returned ascending and non-positive amounts are dropped" do
    d1, d2 = Date.new(2026, 3, 15), Date.new(2026, 6, 15)
    body = chart(
      timestamps: [ ts(d1) ],
      quote: { "open" => [ 10.0 ], "high" => [ 11.0 ], "low" => [ 9.0 ], "close" => [ 10.5 ], "volume" => [ 1 ] },
      dividends: { "b" => { "date" => ts(d2), "amount" => 0.25 },
                   "a" => { "date" => ts(d1), "amount" => 0.2 },
                   "c" => { "date" => ts(d1), "amount" => 0 } }
    )

    divs = build_adapter(stub_chart("AAPL", body)).fetch_daily("AAPL", from: d1, to: d2).dividends

    assert_equal [ d1, d2 ], divs.map(&:ex_date)
    assert_equal [ BigDecimal("0.2"), BigDecimal("0.25") ], divs.map(&:cash_per_share)
  end
  # --- #79: Yahoo spells a class share with a DASH ---------------------------

  # The 913 CAD directory rows carrying more than one dot resolved, then priced
  # to zero, because the URL asked Yahoo for a symbol it does not use. The
  # translation is request-time ONLY: the app's spelling is instrument identity
  # and must not move, or an already-imported ACO.X.TO gains a sibling.
  test "a class-share dot is requested as a dash, and the venue suffix keeps its dot" do
    {
      "ACO.X.TO" => "ACO-X.TO",
      "AQN.PR.A.TO" => "AQN-PR-A.TO",
      "HPS.A.TO" => "HPS-A.TO",
      "AKH.H.V" => "AKH-H.V",
      "AAB.CN" => "AAB.CN",
      "ZEQT.TO" => "ZEQT.TO",
      "FINN.NE" => "FINN.NE",
      # No venue suffix at all: still dashed, because Yahoo's convention for a
      # class share does not depend on the venue. (Bare symbols route to Tiingo,
      # so this is defensive rather than reachable.)
      "BRK.B" => "BRK-B"
    }.each do |stored, expected|
      assert_equal expected, build_adapter(stub_chart("x", "{}")).provider_symbol(stored),
                   "#{stored} must be requested from Yahoo as #{expected}"
    end
  end

  test "the request really uses the dashed spelling while the series keeps the app's" do
    date = Date.new(2026, 7, 2)
    body = chart(
      timestamps: [ ts(date) ],
      quote: { "open" => [ 10.0 ], "high" => [ 11.0 ], "low" => [ 9.0 ], "close" => [ 10.5 ],
               "volume" => [ 1 ] },
      currency: "CAD"
    )

    # The stub is registered for the DASHED path only, so a request using the
    # stored spelling raises Faraday::Adapter::Test::Stubs::NotFound. That is the
    # assertion: this test fails loudly if the translation is dropped.
    series = build_adapter(stub_chart("ACO-X.TO", body))
             .fetch_daily("ACO.X.TO", from: date)

    assert_equal 1, series.bars.size
    assert_equal "ACO.X.TO", series.symbol,
                 "DailySeries must report the APP's symbol — it is instrument identity"
  end

  test "an unknown symbol names both spellings, so the log points somewhere useful" do
    body = { "chart" => { "error" => { "code" => "Not Found" }, "result" => nil } }.to_json

    error = assert_raises(PriceProvider::UnknownSymbol) do
      build_adapter(stub_chart("ACO-X.TO", body)).fetch_daily("ACO.X.TO", from: Date.new(2026, 7, 1))
    end

    assert_includes error.message, "ACO.X.TO"
    assert_includes error.message, "requested as ACO-X.TO"
  end

  test "a symbol needing no translation is not relabelled in its error" do
    body = { "chart" => { "error" => { "code" => "Not Found" }, "result" => nil } }.to_json

    error = assert_raises(PriceProvider::UnknownSymbol) do
      build_adapter(stub_chart("ZEQT.TO", body)).fetch_daily("ZEQT.TO", from: Date.new(2026, 7, 1))
    end

    assert_includes error.message, "ZEQT.TO"
    assert_not_includes error.message, "requested as"
  end
end
