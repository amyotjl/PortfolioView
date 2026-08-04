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
    assert_match(/not a recognized US or Canadian exchange symbol/, result.error)
    assert_no_match(/still downloading/, result.error)
  end

  # --- issue #66: Canadian listings resolve too ------------------------------

  test "a CAD listing on a Canadian venue resolves, with CAD currency" do
    listed("ZEQT.TO", exchange: "TSX", currency: "CAD", asset_type: "ETF")

    result = Instruments::DirectoryResolver.call(symbol: "ZEQT.TO")

    assert result.ok?, result.error
    assert_equal "CAD", result.instrument.currency,
      "stamping USD here would make the instrument disagree with the feed that prices it"
    assert_equal "etf", result.instrument.instrument_type
  end

  test "every Canadian venue is accepted" do
    ListedInstrument::CANADIAN_EXCHANGES.each_with_index do |venue, i|
      sym = "QQC#{i}.TO"
      listed(sym, exchange: venue, currency: "CAD")
      assert Instruments::DirectoryResolver.call(symbol: sym).ok?, "#{venue} should resolve"
    end
  end

  # The currency and the venue must AGREE. Either half alone is a row this app
  # cannot price, because which feed serves it would be a guess.
  test "a CAD row on a US venue does NOT resolve" do
    listed("QQAH", exchange: "NASDAQ", currency: "CAD")

    assert_not Instruments::DirectoryResolver.call(symbol: "QQAH").ok?
  end

  test "a USD row on a Canadian venue does NOT resolve" do
    listed("QQAI.TO", exchange: "TSX", currency: "USD")

    assert_not Instruments::DirectoryResolver.call(symbol: "QQAI.TO").ok?
  end

  test "the rejection message tells a user a Canadian symbol needs its suffix" do
    listed("AAPL", exchange: "NASDAQ")

    result = Instruments::DirectoryResolver.call(symbol: "ZEQT")

    assert_not result.ok?
    assert_match(/venue suffix/, result.error)
  end

  # A bare Canadian ticker must not resolve to the US security of the same name.
  # `instruments` is UNIQUE on upper(symbol) alone, so this is the collision
  # SymbolQualifier and the suffixed directory rows exist to prevent.
  test "a bare ticker never resolves to the Canadian listing of the same name" do
    listed("META.TO", exchange: "TSX", currency: "CAD", asset_type: "Depositary Receipt")

    assert_not Instruments::DirectoryResolver.call(symbol: "META").ok?,
      "typing META must not silently bind to the CAD-hedged CDR"
  end

  # A pre-existing contract test (transactions_controller_test) creates a BARE
  # "SHOP" on the TSX and asserts it is rejected. #66 must not weaken that:
  # Shopify is dual-listed, `instruments` is UNIQUE on upper(symbol) alone, so a
  # bare SHOP could bind to either listing. The suffix is the disambiguator.
  test "a BARE symbol on a Canadian venue is ambiguous and does NOT resolve" do
    listed("SHOP", exchange: "TSX", currency: "CAD")

    assert_not Instruments::DirectoryResolver.call(symbol: "SHOP").ok?,
      "a bare Canadian ticker could bind to the US security of the same name"
  end

  test "the same listing DOES resolve once it carries its venue suffix" do
    listed("SHOP.TO", exchange: "TSX", currency: "CAD")

    result = Instruments::DirectoryResolver.call(symbol: "SHOP.TO")

    assert result.ok?, result.error
    assert_equal "CAD", result.instrument.currency
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
