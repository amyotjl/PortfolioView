require "test_helper"

# DirectoryResolver had no dedicated test file until issue #71 — it was only
# covered incidentally through controller tests, which is why the two behaviours
# pinned here were both free to change silently.
class Instruments::DirectoryResolverTest < ActiveSupport::TestCase
  def listed(symbol, exchange:, currency: "USD", asset_type: "Stock")
    ListedInstrument.create!(symbol: symbol, exchange: exchange,
                             currency: currency, asset_type: asset_type)
  end

  test "resolves a USD row on a US exchange into an Instrument" do
    listed("AAPL", exchange: "NASDAQ")

    result = Instruments::DirectoryResolver.call(symbol: "AAPL")

    assert result.ok?, result.error
    assert_equal "AAPL", result.instrument.symbol
    assert_equal "stock", result.instrument.instrument_type
  end

  # #71 replaced a Ruby `.find` — which walked rows in whatever order Postgres
  # returned them — with `.tradeable.order(:id).first`. Without the explicit
  # order, WHICH venue names the Instrument is unspecified whenever a symbol has
  # more than one US listing, and nothing in the suite noticed: reversing the
  # order failed zero tests.
  test "a symbol with several US listings resolves DETERMINISTICALLY to the first" do
    first  = listed("QQAB", exchange: "NASDAQ")
    second = listed("QQAB", exchange: "NYSE", asset_type: "ETF")
    assert first.id < second.id

    # The ETF row would give instrument_type "etf"; the NASDAQ row gives "stock".
    # Whichever is chosen must be chosen every time.
    5.times do
      Instrument.where("upper(symbol) = 'QQAB'").delete_all
      result = Instruments::DirectoryResolver.call(symbol: "QQAB")
      assert result.ok?, result.error
      assert_equal "stock", result.instrument.instrument_type,
        "the lowest-id listing must win on every call"
    end
  end

  # The scope this now delegates to uses upper(btrim(...)) on BOTH columns, where
  # the Ruby it replaced used `currency.to_s.upcase` and `exchange.to_s.strip.upcase`.
  # These rows exercise the difference.
  test "matches a padded or lower-case currency and exchange, as the Ruby predicate did" do
    listed("QQAC", exchange: " nasdaq ", currency: " usd ")

    assert Instruments::DirectoryResolver.call(symbol: "QQAC").ok?
  end

  test "rejects a non-US exchange" do
    listed("QQAD", exchange: "OTCGREY")

    result = Instruments::DirectoryResolver.call(symbol: "QQAD")

    assert_not result.ok?
    assert_nil result.instrument
  end

  # An empty directory and an unknown symbol are different failures (issue #72).
  # A fresh deploy has no directory at all, so every symbol fails validation —
  # and the old shared message told the user their correct ticker "is not a
  # recognized US-exchange symbol", so they retyped a symbol that was fine.
  test "an EMPTY directory says so, instead of blaming the user's symbol" do
    assert_equal 0, ListedInstrument.count, "precondition: no directory"

    result = Instruments::DirectoryResolver.call(symbol: "AAPL")

    assert_not result.ok?
    assert_match(/still downloading/, result.error)
    assert_no_match(/not a recognized/, result.error,
      "an unprovisioned cache must not be reported as a bad symbol")
  end

  test "a POPULATED directory still rejects an unknown symbol as unrecognized" do
    listed("AAPL", exchange: "NASDAQ")

    result = Instruments::DirectoryResolver.call(symbol: "NOSUCHTICKER")

    assert_not result.ok?
    assert_match(/not a recognized US-exchange symbol/, result.error)
    assert_no_match(/still downloading/, result.error)
  end

  test "rejects a non-USD listing" do
    listed("QQAE", exchange: "NYSE", currency: "CAD")

    assert_not Instruments::DirectoryResolver.call(symbol: "QQAE").ok?
  end

  test "an already-known instrument short-circuits without consulting the directory" do
    existing = Instrument.create!(symbol: "QQAF", instrument_type: "stock",
                                  currency: "USD", skip_provider_jobs: true)
    # No listed_instruments row at all: re-validating against a since-refreshed
    # directory must never reject a symbol the user already holds.
    result = Instruments::DirectoryResolver.call(symbol: "QQAF")

    assert result.ok?
    assert_equal existing.id, result.instrument.id
  end

  test "an ETF listing becomes an etf instrument" do
    listed("QQAG", exchange: "NYSE ARCA", asset_type: "ETF")

    assert_equal "etf", Instruments::DirectoryResolver.call(symbol: "QQAG").instrument.instrument_type
  end

  test "a blank symbol fails without touching the database" do
    result = Instruments::DirectoryResolver.call(symbol: "  ")

    assert_not result.ok?
    assert_equal "is required", result.error
  end
end
