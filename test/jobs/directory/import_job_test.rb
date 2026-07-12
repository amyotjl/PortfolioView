require "test_helper"
require "zip"
require "stringio"

class Directory::ImportJobTest < ActiveSupport::TestCase
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
end
