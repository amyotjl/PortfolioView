require "test_helper"

# Stubbed-HTTP unit tests for the Yahoo EOD adapter (issue #66). All requests
# hit the Faraday :test adapter with recorded fixture bodies (testing-conventions:
# mock at the Faraday boundary) — no test ever touches the real Yahoo endpoint.
#
# The fixtures below are trimmed from REAL responses. The AAPL numbers are the
# genuine split-adjusted closes Yahoo serves for August 2020, and the values
# they must un-adjust to are the genuine raw closes already stored in this
# repo's Tiingo-sourced fixtures — so the central assertion is a cross-source
# agreement, not this adapter agreeing with itself.
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

  # --- reinvested distributions are NOT share-count events -------------------

  # Real values: ZEQT.TO 993:1000 on 2025-12-30. Canadian ETFs declare a
  # year-end reinvested capital-gains distribution and immediately consolidate,
  # so the PRICE moves and the unit count does not.
  test "a n:1000 factor near 1 is a distribution: prices un-adjust, holdings are untouched" do
    dates = [ Date.new(2025, 12, 29), Date.new(2025, 12, 30) ]
    body = chart(
      timestamps: dates.map { |d| ts(d) },
      # Deliberately round numbers so the expected raw value is exact: Yahoo
      # divided the pre-date price by 0.993, so an adjusted 1000 is a raw 993.
      quote: { "open" => [ 1000.0, 20.0 ], "high" => [ 1100.0, 21.0 ], "low" => [ 900.0, 19.0 ],
               "close" => [ 1000.0, 20.51 ], "volume" => [ 1, 1 ] },
      splits: { "y" => { "date" => ts(dates.last), "numerator" => 993.0, "denominator" => 1000.0 } },
      currency: "CAD"
    )

    series = build_adapter(stub_chart("ZEQT.TO", body)).fetch_daily("ZEQT.TO", from: dates.first, to: dates.last)

    assert_empty series.splits,
      "a reinvested distribution must never become a SplitEvent — it would shrink the holder's shares ~0.7%"
    assert_equal BigDecimal("993"), series.bars.first.close,
      "but the PRICE must still be un-adjusted by it, or history sits 0.7% low"
    assert(series.warnings.any? { |w| w.include?("reinvested distribution") },
      "the reclassification must be visible, not silent")
  end

  # #66's gate broke the previous magnitude-based rule with real securities:
  # Yahoo encodes SPIN-OFFS in the same n:1000 shape, just larger, so a band
  # around 1 classified the same corporate action two different ways by size.
  # A spin-off does not change the parent's share count either.
  test "a spin-off factor is price-only, however large — magnitude must not decide" do
    d = Date.new(2024, 10, 2)
    body = chart(
      timestamps: [ ts(d) ],
      quote: { "open" => [ 10.0 ], "high" => [ 10.0 ], "low" => [ 10.0 ], "close" => [ 10.0 ], "volume" => [ 1 ] },
      # TRP.TO, the South Bow spin-off: holders kept 1:1 and received 0.2 SOBO.
      splits: { "s" => { "date" => ts(d), "numerator" => 1097.0, "denominator" => 1000.0 } }
    )

    series = build_adapter(stub_chart("TRP.TO", body)).fetch_daily("TRP.TO", from: d, to: d)

    assert_empty series.splits,
      "1097:1000 as a SplitEvent would invent 9.7% of phantom shares"
    assert(series.warnings.any? { |w| w.include?("price-only") },
      "a kept-or-dropped decision on a large-denominator factor must never be silent")
  end

  test "two spin-offs of different sizes classify the SAME way" do
    small, large = Date.new(2013, 4, 15), Date.new(2022, 12, 12)
    body = chart(
      timestamps: [ ts(small), ts(large) ],
      quote: { "open" => [ 10.0, 10.0 ], "high" => [ 10.0, 10.0 ], "low" => [ 10.0, 10.0 ],
               "close" => [ 10.0, 10.0 ], "volume" => [ 1, 1 ] },
      # Both BN.TO, both spin-offs; the old rule kept one and dropped the other.
      splits: { "a" => { "date" => ts(small), "numerator" => 1033.0, "denominator" => 1000.0 },
                "b" => { "date" => ts(large), "numerator" => 1237.0, "denominator" => 1000.0 } }
    )

    series = build_adapter(stub_chart("BN.TO", body)).fetch_daily("BN.TO", from: small, to: large)

    assert_empty series.splits, "classification must not depend on the size of the factor"
    assert_equal 2, series.warnings.count { |w| w.include?("price-only") }
  end

  # A windowed fetch used to under-correct: Yahoo only reports events INSIDE the
  # requested window, so a window ending before a split returned prices already
  # divided by it with the split absent. Measured at 91.20 against a raw 364.80.
  test "a windowed fetch is still un-adjusted by splits AFTER the window" do
    jan, jun, aug = Date.new(2020, 1, 2), Date.new(2020, 6, 30), Date.new(2020, 8, 31)
    body = chart(
      timestamps: [ ts(jan), ts(jun), ts(aug) ],
      quote: { "open" => [ 10.0, 10.0, 10.0 ], "high" => [ 100.0, 100.0, 100.0 ],
               "low" => [ 1.0, 1.0, 1.0 ], "close" => [ 91.2, 91.2, 129.04 ], "volume" => [ 1, 1, 1 ] },
      splits: { "s" => { "date" => ts(aug), "numerator" => 4.0, "denominator" => 1.0 } }
    )

    series = build_adapter(stub_chart("AAPL", body)).fetch_daily("AAPL", from: jan, to: jun)

    assert_equal [ jan, jun ], series.bars.map(&:date), "the window still bounds what is RETURNED"
    assert_equal BigDecimal("364.8"), series.bars.first.close,
      "but the August 4:1 must still have been reversed"
    assert_empty series.splits, "an event after the window must not be handed back to be written"
  end

  # The slicing test above cannot catch a NARROWED REQUEST, because a stubbed
  # response is returned whatever the query says — a mutation that puts `to:`
  # back into period2 leaves it green. This asserts the request itself.
  test "a `to:` never narrows the REQUEST, only the returned window" do
    captured = nil
    stubs = Faraday::Adapter::Test::Stubs.new
    stubs.get("/v8/finance/chart/AAPL") do |env|
      captured = env.params
      [ 200, { "Content-Type" => "application/json" },
        chart(timestamps: [], quote: {}) ]
    end

    travel_to Time.utc(2026, 7, 15, 12) do
      build_adapter(stubs).fetch_daily("AAPL", from: Date.new(2020, 1, 2), to: Date.new(2020, 6, 30))

      expected = (Trading::Calendar.today + 1).to_time(:utc).to_i
      assert_equal expected.to_s, captured["period2"].to_s,
        "period2 must run through today so every later split is present to un-adjust with"
    end
  end

  # THE MIRROR IMAGE of the spin-off finding. A consolidation arrives as 1:300,
  # so a denominator test ALONE routes the most share-count-changing event there
  # is into the price-only branch. Live on real holdings: HMMC.TO has a 1:300 on
  # 2023-01-04, and VTI.CN carries two 1:100s that would turn a CAD 1.00
  # position into CAD 2,100.
  test "a consolidation (1:300) IS a share-count split despite its large denominator" do
    d = Date.new(2023, 1, 4)
    body = chart(
      timestamps: [ ts(d) ],
      quote: { "open" => [ 7.5 ], "high" => [ 7.5 ], "low" => [ 7.5 ], "close" => [ 7.5 ], "volume" => [ 1 ] },
      splits: { "c" => { "date" => ts(d), "numerator" => 1.0, "denominator" => 300.0 } },
      currency: "CAD"
    )

    series = build_adapter(stub_chart("HMMC.TO", body)).fetch_daily("HMMC.TO", from: d, to: d)

    assert_equal 1, series.splits.size,
      "suppressing a consolidation overstates the holder's position by the ratio"
    assert_in_delta BigDecimal("0.003333"), series.splits.first.ratio, BigDecimal("0.000001")
    assert_empty series.warnings.select { |w| w.include?("price-only") }
  end

  test "the two halves of the rule cover what the other misses" do
    d = Date.new(2024, 6, 3)
    cases = {
      # num > 1 AND den >= 100 -> price-only
      [ 993.0, 1000.0 ]  => :suppressed,   # reinvested distribution
      [ 1097.0, 1000.0 ] => :suppressed,   # spin-off
      # num == 1 -> a consolidation, share-count event even with a big denominator
      [ 1.0, 300.0 ]     => :split,
      [ 1.0, 100.0 ]     => :split,
      # small denominators are ordinary splits either way
      [ 4.0, 1.0 ]       => :split,
      [ 3.0, 2.0 ]       => :split,
      [ 1.0, 8.0 ]       => :split,        # ordinary reverse split
      [ 21.0, 20.0 ]     => :split         # 5% stock dividend
    }

    cases.each do |(num, den), expected|
      body = chart(
        timestamps: [ ts(d) ],
        quote: { "open" => [ 10.0 ], "high" => [ 10.0 ], "low" => [ 10.0 ], "close" => [ 10.0 ], "volume" => [ 1 ] },
        splits: { "x" => { "date" => ts(d), "numerator" => num, "denominator" => den } }
      )
      series = build_adapter(stub_chart("XYZ", body)).fetch_daily("XYZ", from: d, to: d)
      actual = series.splits.any? ? :split : :suppressed

      assert_equal expected, actual, "#{num.to_i}:#{den.to_i} should be #{expected}"
    end
  end

  test "a genuine 5% stock dividend (21:20) IS a share-count split despite being near 1" do
    d = Date.new(2024, 6, 3)
    body = chart(
      timestamps: [ ts(d) ],
      quote: { "open" => [ 10.0 ], "high" => [ 10.0 ], "low" => [ 10.0 ], "close" => [ 10.0 ], "volume" => [ 1 ] },
      splits: { "z" => { "date" => ts(d), "numerator" => 21.0, "denominator" => 20.0 } }
    )

    series = build_adapter(stub_chart("XYZ", body)).fetch_daily("XYZ", from: d, to: d)

    assert_equal [ BigDecimal("1.05") ], series.splits.map(&:ratio),
      "the denominator, not mere proximity to 1, is what separates a distribution from a stock dividend"
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
end
