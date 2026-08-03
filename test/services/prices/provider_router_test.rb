require "test_helper"

# Which provider serves which instrument (issue #66). Tiingo's directory has
# zero Canadian rows, so this routing is the difference between a CAD holding
# having price history and having none.
class Prices::ProviderRouterTest < ActiveSupport::TestCase
  def route(symbol) = Prices::ProviderRouter.call(symbol: symbol)

  test "a bare US symbol still routes to Tiingo, budgeted and failover-capable" do
    r = route("AAPL")

    assert_equal PriceProvider::Tiingo, r.provider_class
    assert_equal "tiingo", r.name
    assert r.budgeted?, "the US path must keep charging Tiingo's quota"
    assert r.failover?, "the US path must keep its TwelveData failover"
  end

  test "a venue-suffixed symbol routes to Yahoo, unbudgeted and without failover" do
    r = route("ZEQT.TO")

    assert_equal PriceProvider::Yahoo, r.provider_class
    assert_equal "yahoo", r.name
    assert_not r.budgeted?, "Yahoo is keyless — there is no account to charge"
    assert_not r.failover?,
      "TwelveData 403s Canadian symbols and returns no events; failing over would " \
      "swap the only source that has the data for one that cannot serve it"
  end

  test "every SymbolQualifier venue suffix routes to Yahoo" do
    Portfolios::Transfer::SymbolQualifier::KNOWN_SUFFIXES.each do |suffix|
      r = route("XYZ#{suffix}")
      assert_equal "yahoo", r.name, "#{suffix} should route to Yahoo"
    end
  end

  # The suffix list is SymbolQualifier's, deliberately not a second copy — if
  # the importer and the price pipeline disagreed about what counts as non-US,
  # a symbol could be minted as `META.TO` and then priced as US `META`.
  test "the non-US test is SymbolQualifier's list, not a private one" do
    assert Prices::ProviderRouter.non_us?("FINN.NE")
    assert_includes Portfolios::Transfer::SymbolQualifier::KNOWN_SUFFIXES, ".NE"
  end

  test "a share-class dot is not a venue suffix" do
    # HPS.A is a US share class, not a Canadian listing. Routing it to Yahoo
    # would take it off Tiingo's raw feed for no reason.
    assert_equal "tiingo", route("HPS.A").name
    assert_equal "tiingo", route("BRK-B").name
  end

  test "routing is case- and whitespace-insensitive" do
    assert_equal "yahoo", route("  zeqt.to  ").name
  end

  # Asking who serves a symbol must not BUILD anything: a keyed adapter raises
  # ConfigurationError from its constructor when its key is unset (the test env
  # nils every provider key deliberately), so an eager build would pre-empt the
  # caller's budget check and turn a reschedulable BudgetExceeded into a
  # terminal ConfigurationError.
  test "routing constructs no provider, so a missing key cannot pre-empt a budget check" do
    original = ENV.delete("TIINGO_API_KEY")

    assert_nothing_raised { route("AAPL") }
    assert_raises(PriceProvider::ConfigurationError) { route("AAPL").provider }
  ensure
    ENV["TIINGO_API_KEY"] = original if original
  end

  test "the Yahoo route builds without any key at all" do
    assert_instance_of PriceProvider::Yahoo, route("ZEQT.TO").provider
  end

  test "#for reads the symbol off an instrument" do
    instrument = Instrument.create!(symbol: "VDY.TO", instrument_type: "etf",
                                    currency: "CAD", skip_provider_jobs: true)

    assert_equal "yahoo", Prices::ProviderRouter.for(instrument).name
  end
end
