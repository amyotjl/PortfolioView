require "test_helper"
require "zip"
require "stringio"

class Directory::ImportJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  HEADER = "ticker,exchange,assetType,priceCurrency,startDate,endDate".freeze

  # Wraps CSV text in a one-entry ZIP, matching Tiingo's supported_tickers.zip.
  def zip_of(csv_body, entry: "supported_tickers.csv")
    Zip::OutputStream.write_buffer do |zos|
      zos.put_next_entry(entry)
      zos.write("#{HEADER}\n#{csv_body}")
    end.string
  end

  test "parses the zipped CSV and upserts listed_instruments" do
    data = zip_of(<<~CSV)
      AAPL,NASDAQ,Stock,USD,1980-12-12,2026-07-10
      SPY,NYSE ARCA,ETF,USD,1993-01-29,2026-07-10
      MSFT,NASDAQ,Stock,USD,1986-03-13,2026-07-10
    CSV

    result = Directory::ImportJob.perform_now(min_rows: 1, zip_data: data)

    assert_equal 3, ListedInstrument.count
    assert_equal 3, result[:imported]
    aapl = ListedInstrument.find_by(symbol: "AAPL")
    assert_equal "NASDAQ", aapl.exchange
    assert_equal "Stock", aapl.asset_type
    assert_equal "USD", aapl.currency
  end

  test "is idempotent: re-import keeps counts stable and updates changed fields in place" do
    Directory::ImportJob.perform_now(min_rows: 1, zip_data: zip_of("AAPL,NASDAQ,Stock,USD,1980-12-12,2026-07-10\n"))
    assert_equal 1, ListedInstrument.count

    # Same (symbol, exchange), asset_type changed → update in place, no new row.
    Directory::ImportJob.perform_now(min_rows: 1, zip_data: zip_of("AAPL,NASDAQ,ETF,USD,1980-12-12,2026-07-11\n"))

    assert_equal 1, ListedInstrument.count
    assert_equal "ETF", ListedInstrument.find_by(symbol: "AAPL").asset_type
  end

  test "skips malformed rows and still imports the valid ones" do
    long_symbol = "X" * 40
    data = zip_of(<<~CSV)
      AAPL,NASDAQ,Stock,USD,1980-12-12,2026-07-10
      ,NASDAQ,Stock,USD,1980-12-12,2026-07-10
      #{long_symbol},NASDAQ,Stock,USD,1980-12-12,2026-07-10
      MSFT,NASDAQ,Stock,USD,1986-03-13,2026-07-10
    CSV

    result = Directory::ImportJob.perform_now(min_rows: 1, zip_data: data)

    assert_equal 2, result[:imported]
    assert_equal %w[AAPL MSFT], ListedInstrument.order(:symbol).pluck(:symbol)
  end

  test "collapses duplicate (symbol, exchange) rows so the batch never self-conflicts" do
    data = zip_of(<<~CSV)
      AAPL,NASDAQ,Stock,USD,1980-12-12,2000-01-01
      AAPL,NASDAQ,Stock,USD,2000-01-02,2026-07-10
    CSV

    assert_nothing_raised do
      Directory::ImportJob.perform_now(min_rows: 1, zip_data: data)
    end
    assert_equal 1, ListedInstrument.where(symbol: "AAPL", exchange: "NASDAQ").count
  end

  test "sanity guard aborts on an implausibly small file, keeping the directory intact" do
    ListedInstrument.create!(symbol: "EXISTING", exchange: "NYSE", asset_type: "Stock", currency: "USD")
    data = zip_of("AAPL,NASDAQ,Stock,USD,1980-12-12,2026-07-10\n") # 1 row, below the threshold

    result = Directory::ImportJob.perform_now(min_rows: 5, zip_data: data)

    assert result[:aborted]
    assert_equal 0, result[:imported]
    assert_equal [ "EXISTING" ], ListedInstrument.pluck(:symbol)
    assert_nil ListedInstrument.find_by(symbol: "AAPL")
  end

  test "raises MalformedResponse when the zip has no CSV entry" do
    data = Zip::OutputStream.write_buffer { |zos| zos.put_next_entry("readme.txt"); zos.write("nope") }.string

    assert_raises PriceProvider::MalformedResponse do
      Directory::ImportJob.perform_now(min_rows: 1, zip_data: data)
    end
  end

  # --- name enrichment must survive the weekly re-import (issue #63) ---------

  test "a re-import does NOT clobber an enriched name back to null" do
    Directory::ImportJob.perform_now(min_rows: 1, zip_data: zip_of("MSFT,NASDAQ,Stock,USD,1986-03-13,2026-07-10\n"))
    ListedInstrument.find_by(symbol: "MSFT").update!(name: "Microsoft Corporation")

    # Every row this file carries has name: nil — the whole failure mode.
    Directory::ImportJob.perform_now(min_rows: 1, zip_data: zip_of("MSFT,NASDAQ,Stock,USD,1986-03-13,2026-07-11\n"))

    assert_equal "Microsoft Corporation", ListedInstrument.find_by(symbol: "MSFT").name
  end

  test "a re-import still updates the columns the file DOES own" do
    Directory::ImportJob.perform_now(min_rows: 1, zip_data: zip_of("MSFT,NASDAQ,Stock,USD,1986-03-13,2026-07-10\n"))
    ListedInstrument.find_by(symbol: "MSFT").update!(name: "Microsoft Corporation")

    Directory::ImportJob.perform_now(min_rows: 1, zip_data: zip_of("MSFT,NASDAQ,ETF,CAD,1986-03-13,2026-07-11\n"))

    row = ListedInstrument.find_by(symbol: "MSFT")
    assert_equal "ETF", row.asset_type, "preserving the name must not freeze the whole row"
    assert_equal "CAD", row.currency
    assert_equal "Microsoft Corporation", row.name
  end

  # `assert_not_nil` on these would be vacuous — both columns are NOT NULL, so a
  # broken record_timestamps: would raise on INSERT rather than store a nil.
  # Assert they carry a plausible CURRENT time instead, which is what the option
  # is actually responsible for.
  test "a fresh insert still lands with timestamps set" do
    Directory::ImportJob.perform_now(min_rows: 1, zip_data: zip_of("MSFT,NASDAQ,Stock,USD,1986-03-13,2026-07-10\n"))

    row = ListedInstrument.find_by(symbol: "MSFT")
    assert_in_delta Time.current, row.created_at, 5.minutes,
      "on_duplicate: must not disable record_timestamps on the INSERT path"
    assert_in_delta Time.current, row.updated_at, 5.minutes
  end

  # --- listing dates, the liveness signal search ranks on (issue #63) --------

  test "stores startDate and endDate, which the importer used to discard" do
    Directory::ImportJob.perform_now(min_rows: 1, zip_data: zip_of("MSFT,NASDAQ,Stock,USD,1986-03-13,2026-07-10\n"))

    row = ListedInstrument.find_by(symbol: "MSFT")
    assert_equal Date.new(1986, 3, 13), row.start_date
    assert_equal Date.new(2026, 7, 10), row.end_date
  end

  test "a re-import refreshes end_date, so a listing that dies stops ranking as live" do
    Directory::ImportJob.perform_now(min_rows: 1, zip_data: zip_of("AABA,NASDAQ,Stock,USD,1996-04-12,2026-07-10\n"))
    Directory::ImportJob.perform_now(min_rows: 1, zip_data: zip_of("AABA,NASDAQ,Stock,USD,1996-04-12,2019-10-02\n"))

    assert_equal Date.new(2019, 10, 2), ListedInstrument.find_by(symbol: "AABA").end_date
  end

  test "a blank or unparseable date imports the row with nil rather than dropping it" do
    data = zip_of(<<~CSV)
      AAPL,NASDAQ,Stock,USD,,
      MSFT,NASDAQ,Stock,USD,not-a-date,also-not-a-date
    CSV

    result = Directory::ImportJob.perform_now(min_rows: 1, zip_data: data)

    assert_equal 2, result[:imported], "a bad date must not cost us the ticker"
    assert_nil ListedInstrument.find_by(symbol: "AAPL").end_date
    assert_nil ListedInstrument.find_by(symbol: "MSFT").end_date
  end

  test "a successful import schedules name re-enrichment" do
    assert_enqueued_with(job: Directory::EnrichNamesJob) do
      Directory::ImportJob.perform_now(min_rows: 1, zip_data: zip_of("MSFT,NASDAQ,Stock,USD,1986-03-13,2026-07-10\n"))
    end
  end

  test "an aborted import does not schedule enrichment" do
    assert_no_enqueued_jobs(only: Directory::EnrichNamesJob) do
      Directory::ImportJob.perform_now(min_rows: 5, zip_data: zip_of("AAPL,NASDAQ,Stock,USD,1980-12-12,2026-07-10\n"))
    end
  end
end
