require "test_helper"

# Canadian directory import (issue #66). Tiingo's bulk file contains zero
# Canadian rows, so without this job a Canadian ticker can be neither typed,
# autocompleted, nor validated.
class Directory::ImportCanadianJobTest < ActiveSupport::TestCase
  # Shapes taken from real Twelve Data /stocks and /etf responses.
  STOCK_ROWS = [
    { "symbol" => "ABX", "name" => "Barrick Mining Corp", "exchange" => "TSX",
      "mic_code" => "XTSE", "currency" => "CAD", "type" => "Common Stock" },
    # A REAL row whose symbol already ends in a dot. It is kept in the default
    # fixture on purpose: suffixing it used to produce `AAAJ.PR..V`, and this file
    # used to ASSERT that shape as stored output — enshrining the defect #66's
    # gate later filed as Finding 5. It must now be dropped, everywhere.
    { "symbol" => "AAAJ.PR.", "name" => "AAJ Capital 3 Corp.", "exchange" => "TSXV",
      "mic_code" => "XTSX", "currency" => "CAD", "type" => "Common Stock" }
  ].freeze

  ETF_ROWS = [
    { "symbol" => "ZEQT", "name" => "BMO All-Equity ETF", "exchange" => "TSX",
      "mic_code" => "XTSE", "currency" => "CAD" },
    { "symbol" => "FINN", "name" => "Fidelity Global Innovators ETF", "exchange" => "NEO",
      "mic_code" => "NEOE", "currency" => "CAD" }
  ].freeze

  # Stands in for PriceProvider::TwelveData without touching HTTP.
  class StubReference
    attr_reader :calls

    def initialize(stocks: [], etf: [], raise_on: nil)
      @stocks = stocks
      @etf = etf
      @raise_on = raise_on
      @calls = []
    end

    def fetch_country_listings(country:, kind:)
      @calls << [ country, kind ]
      raise PriceProvider::ServerError, "boom" if @raise_on == kind

      kind == "etf" ? @etf : @stocks
    end
  end

  def run_job(stocks: STOCK_ROWS, etf: ETF_ROWS, raise_on: nil, min_rows: 1)
    provider = StubReference.new(stocks:, etf:, raise_on:)
    result = Directory::ImportCanadianJob.perform_now(min_rows:, provider:)
    [ result, provider ]
  end

  # --- the point of the job -------------------------------------------------

  test "stores symbols VENUE-SUFFIXED so a Canadian ticker cannot alias a US one" do
    run_job

    assert_equal %w[ABX.TO FINN.NE ZEQT.TO].sort,
                 ListedInstrument.order(:symbol).pluck(:symbol).sort
  end

  test "carries the NAME, which the Tiingo directory has never had" do
    run_job

    assert_equal "BMO All-Equity ETF", ListedInstrument.find_by(symbol: "ZEQT.TO").name
    assert_equal "Barrick Mining Corp", ListedInstrument.find_by(symbol: "ABX.TO").name
  end

  test "the imported rows are findable by the existing search — no new code path" do
    run_job

    assert_includes ListedInstrument.search("ZEQT").map(&:symbol), "ZEQT.TO"
    assert_includes ListedInstrument.search("BMO All-Equity").map(&:symbol), "ZEQT.TO",
      "name search is what the Twelve Data names buy us"
  end

  test "an ETF row is typed ETF even though /etf sends no type field" do
    run_job

    assert_equal "ETF", ListedInstrument.find_by(symbol: "ZEQT.TO").asset_type
    assert_equal "Common Stock", ListedInstrument.find_by(symbol: "ABX.TO").asset_type
  end

  test "both endpoints are queried for Canada" do
    _, provider = run_job

    assert_equal [ [ "Canada", "stocks" ], [ "Canada", "etf" ] ], provider.calls
  end

  # --- refusing to store something ambiguous --------------------------------

  test "an UNMAPPED mic is skipped rather than stored as a bare symbol" do
    # A bare "XYZ" would be indistinguishable from the US ticker XYZ, and
    # `instruments` is UNIQUE on upper(symbol) alone.
    run_job(stocks: [ { "symbol" => "XYZ", "name" => "Somewhere Inc", "exchange" => "???",
                        "mic_code" => "XXXX", "currency" => "CAD", "type" => "Common Stock" } ],
            etf: [])

    assert_nil ListedInstrument.find_by(symbol: "XYZ")
    assert_equal 0, ListedInstrument.count
  end

  # ~50 real Twelve Data rows carry a space in the symbol (#66's gate). Stored,
  # they would be autocompletable and resolvable and then blow up at fetch time
  # on PriceProvider::Base#normalize_symbol — worse than never appearing.
  test "a symbol the price adapters cannot request is skipped" do
    run_job(stocks: [ { "symbol" => "AAB PR A", "name" => "Odd Row", "exchange" => "TSX",
                        "mic_code" => "XTSE", "currency" => "CAD", "type" => "Common Stock" } ],
            etf: [])

    assert_equal 0, ListedInstrument.where("symbol LIKE '%% %%'").count
    assert_equal 0, ListedInstrument.count
  end

  # 151 real Twelve Data rows carry a symbol that already ENDS in a dot
  # (`AAAJ.PR.`), and suffixing one produces `AAAJ.PR..V` — a shape SYMBOL_FORMAT
  # happily admits and no venue ever issued (#66's gate, Finding 5).
  test "a symbol with an empty dot-separated segment is skipped" do
    run_job(stocks: [ { "symbol" => "AAAJ.PR.", "name" => "Trailing Dot Pref", "exchange" => "TSXV",
                        "mic_code" => "XTSX", "currency" => "CAD", "type" => "Preferred Stock" },
                      { "symbol" => ".LEAD", "name" => "Leading Dot", "exchange" => "TSXV",
                        "mic_code" => "XTSX", "currency" => "CAD", "type" => "Common Stock" } ],
            etf: [])

    assert_equal 0, ListedInstrument.count
    assert_equal 0, ListedInstrument.where("symbol LIKE '%..%'").count
  end

  # The other 913 multi-dot rows name REAL securities and must survive: the
  # dot-versus-dash spelling is a separate, coordinated change (it touches #68's
  # instrument identity), so this guard must not quietly take them out with the
  # malformed ones.
  test "a legitimate class or series symbol is still imported" do
    run_job(stocks: [ { "symbol" => "ACO.X", "name" => "Atco Class I", "exchange" => "TSX",
                        "mic_code" => "XTSE", "currency" => "CAD", "type" => "Common Stock" } ],
            etf: [])

    assert_equal [ "ACO.X.TO" ], ListedInstrument.pluck(:symbol)
  end

  test "every imported symbol satisfies the price adapters' symbol format" do
    run_job

    ListedInstrument.pluck(:symbol).each do |sym|
      assert_match PriceProvider::Base::SYMBOL_FORMAT, sym, "#{sym} could never be fetched"
    end
  end

  test "a blank symbol is skipped without failing the run" do
    result, = run_job(stocks: [ { "symbol" => "", "mic_code" => "XTSE", "currency" => "CAD" } ], etf: ETF_ROWS)

    assert_not result[:aborted]
    assert_equal 2, result[:imported]
  end

  # --- resilience -----------------------------------------------------------

  test "one endpoint failing does not lose the other" do
    result, = run_job(raise_on: "stocks")

    assert_equal 2, result[:imported], "the ETF rows must still land"
    assert_not result[:aborted]
  end

  test "an implausibly small result aborts and keeps the existing directory" do
    ListedInstrument.create!(symbol: "EXISTING.TO", exchange: "TSX", asset_type: "ETF", currency: "CAD")

    result, = run_job(min_rows: 500)

    assert result[:aborted]
    assert_equal 0, result[:imported]
    assert_equal [ "EXISTING.TO" ], ListedInstrument.pluck(:symbol)
  end

  test "re-import is idempotent and does not duplicate rows" do
    run_job
    before = ListedInstrument.count

    run_job

    assert_equal before, ListedInstrument.count
  end

  test "a re-import does not clobber an enriched name" do
    run_job
    ListedInstrument.find_by(symbol: "ZEQT.TO").update!(name: "Corrected Name")

    run_job(etf: [ ETF_ROWS.first.merge("name" => nil), ETF_ROWS.last ])

    assert_equal "Corrected Name", ListedInstrument.find_by(symbol: "ZEQT.TO").name
  end

  test "duplicate (symbol, exchange) rows in one response collapse instead of conflicting" do
    dupes = [ ETF_ROWS.first, ETF_ROWS.first.merge("name" => "Second Copy") ]

    assert_nothing_raised { run_job(stocks: [], etf: dupes) }
    assert_equal 1, ListedInstrument.where(symbol: "ZEQT.TO").count
  end

  # The US directory and this one share a table; neither may disturb the other.
  test "existing US rows are untouched" do
    ListedInstrument.create!(symbol: "AAPL", exchange: "NASDAQ", asset_type: "Stock", currency: "USD")

    run_job

    aapl = ListedInstrument.find_by(symbol: "AAPL")
    assert_equal "USD", aapl.currency
    assert_equal "NASDAQ", aapl.exchange
  end
end
