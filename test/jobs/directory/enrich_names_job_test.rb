require "test_helper"

# Directory name enrichment (issue #63): copy names this app already paid FMP
# for into the directory that has none, at zero extra quota.
class Directory::EnrichNamesJobTest < ActiveJob::TestCase
  def listed(symbol, exchange: "NASDAQ", asset_type: "Stock", currency: "USD", name: nil)
    ListedInstrument.create!(symbol: symbol, exchange: exchange, asset_type: asset_type,
                             currency: currency, name: name)
  end

  def instrument(symbol, name:, instrument_type: "stock")
    Instrument.create!(symbol: symbol, name: name, instrument_type: instrument_type,
                       currency: "USD", skip_provider_jobs: true)
  end

  test "writes the instrument's name onto the matching directory row" do
    row = listed("MSFT")
    instrument("MSFT", name: "Microsoft Corporation")

    result = Directory::EnrichNamesJob.perform_now

    assert_equal 1, result[:enriched]
    assert_equal "Microsoft Corporation", row.reload.name
  end

  test "makes the enriched row findable BY NAME, which is the whole point" do
    listed("MSFT")
    instrument("MSFT", name: "Microsoft Corporation")

    assert_equal [], ListedInstrument.search("Microsoft").map(&:symbol)
    Directory::EnrichNamesJob.perform_now
    assert_equal [ "MSFT" ], ListedInstrument.search("Microsoft").map(&:symbol)
  end

  test "matches case-insensitively on symbol" do
    row = ListedInstrument.new(symbol: "msft", exchange: "NASDAQ", asset_type: "Stock", currency: "USD")
    row.save!(validate: false)
    instrument("MSFT", name: "Microsoft Corporation")

    Directory::EnrichNamesJob.perform_now

    assert_equal "Microsoft Corporation", row.reload.name
  end

  # NOTE: do NOT assert `updated_at` is unchanged here. The job writes
  # CURRENT_TIMESTAMP, which Postgres resolves to transaction_timestamp() — a
  # constant for the whole transaction — and these tests run inside one. Such an
  # assertion passes whether or not the row was rewritten, so it proves nothing.
  # The row count is the honest signal, so assert on that and on the untouched
  # data instead.
  test "is idempotent — a second run matches zero rows" do
    row = listed("MSFT")
    instrument("MSFT", name: "Microsoft Corporation")
    assert_equal 1, Directory::EnrichNamesJob.perform_now[:enriched]

    result = Directory::EnrichNamesJob.perform_now

    assert_equal 0, result[:enriched],
      "the IS DISTINCT FROM guard must make a repeat run a no-op"
    assert_equal "Microsoft Corporation", row.reload.name
  end

  test "the IS DISTINCT FROM guard is what makes it a no-op, not luck" do
    listed("MSFT")
    instrument("MSFT", name: "Microsoft Corporation")
    Directory::EnrichNamesJob.perform_now

    # Change the directory row away from the instrument's name and the next run
    # must pick it up again — proving the zero above came from the values
    # agreeing, not from the job having stopped working after one pass.
    ListedInstrument.find_by(symbol: "MSFT").update!(name: "Stale Name")

    assert_equal 1, Directory::EnrichNamesJob.perform_now[:enriched]
  end

  test "a later FMP correction overwrites the stale name" do
    row = listed("MSFT", name: "Microsoft Corp")
    instrument("MSFT", name: "Microsoft Corporation")

    Directory::EnrichNamesJob.perform_now

    assert_equal "Microsoft Corporation", row.reload.name
  end

  # --- what it must NOT touch ----------------------------------------------

  test "does not label a different security that merely shares the ticker" do
    # The real directory has exactly this: MSFC is a NASDAQ Stock and a BATS ETF.
    stock = listed("MSFC", exchange: "NASDAQ", asset_type: "Stock")
    etf   = listed("MSFC", exchange: "BATS",   asset_type: "ETF")
    instrument("MSFC", name: "Some Operating Company", instrument_type: "stock")

    Directory::EnrichNamesJob.perform_now

    assert_equal "Some Operating Company", stock.reload.name
    assert_nil etf.reload.name, "an ETF must not inherit an equity's company name"
  end

  test "an ETF instrument enriches the ETF row, not the equity row" do
    stock = listed("MSFC", exchange: "NASDAQ", asset_type: "Stock")
    etf   = listed("MSFC", exchange: "BATS",   asset_type: "ETF")
    instrument("MSFC", name: "Some Index ETF", instrument_type: "etf")

    Directory::EnrichNamesJob.perform_now

    assert_equal "Some Index ETF", etf.reload.name
    assert_nil stock.reload.name
  end

  test "leaves untradeable venues alone — they can never be the held security" do
    row = listed("MSFT", exchange: "OTCGREY")
    instrument("MSFT", name: "Microsoft Corporation")

    Directory::EnrichNamesJob.perform_now

    assert_nil row.reload.name
  end

  test "leaves non-USD rows alone" do
    row = listed("MSFT", currency: "CAD")
    instrument("MSFT", name: "Microsoft Corporation")

    Directory::EnrichNamesJob.perform_now

    assert_nil row.reload.name
  end

  test "a non-USD INSTRUMENT never labels the USD listing that shares its ticker" do
    # SymbolQualifier emits a bare ticker for a non-USD instrument when the file
    # names no MIC and no exchange, so a CAD holding can exist as plain "AC".
    # The US directory row for AC is a different company entirely, and the
    # asset-class guard does not separate them — both are 'stock'.
    row = listed("AC", exchange: "NYSE", asset_type: "Stock", currency: "USD")
    Instrument.create!(symbol: "AC", name: "Air Canada", instrument_type: "stock",
                       currency: "CAD", skip_provider_jobs: true)

    assert_equal 0, Directory::EnrichNamesJob.perform_now[:enriched]
    assert_nil row.reload.name, "a CAD instrument must not name a USD listing"
  end

  test "ignores a blank instrument name rather than writing an empty label" do
    row = listed("MSFT")
    instrument("MSFT", name: "   ")

    assert_equal 0, Directory::EnrichNamesJob.perform_now[:enriched]
    assert_nil row.reload.name
  end

  test "spends no provider quota and makes no HTTP call" do
    listed("MSFT")
    instrument("MSFT", name: "Microsoft Corporation")

    # Any adapter reaching for the network in test raises; assert the budget is
    # untouched too, since that is the reason this source was chosen.
    assert_no_difference -> { PriceProvider::Budget.new("fmp").requests_today } do
      Directory::EnrichNamesJob.perform_now
    end
  end
end
