require "test_helper"

class Instruments::MetadataJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include PricePipelineTestHelper

  ET = ActiveSupport::TimeZone["America/New_York"]

  def stock_profile(symbol: "AAPL", sector: "Technology", industry: "Consumer Electronics")
    PriceProvider::Profile.new(symbol: symbol, name: "Apple Inc.", sector: sector,
                               industry: industry, instrument_type: "stock", found: true)
  end

  def etf_profile(symbol: "SPY")
    PriceProvider::Profile.new(symbol: symbol, name: "SPDR S&P 500 ETF", sector: nil,
                               industry: nil, instrument_type: "etf", found: true)
  end

  def run_job(instrument, provider, **opts)
    travel_to ET.local(2026, 7, 11, 12) do
      stub_new(PriceProvider::Fmp, provider) do
        Instruments::MetadataJob.perform_now(instrument.id, **opts)
      end
    end
  end

  test "persists sector, industry, and instrument_type from the FMP profile" do
    instrument = create_instrument(symbol: "AAPL", instrument_type: "stock")

    run_job(instrument, StubProvider.new(series: stock_profile))

    instrument.reload
    assert_equal "Technology", instrument.sector
    assert_equal "Consumer Electronics", instrument.industry
    assert_equal "stock", instrument.instrument_type
    assert_equal "Apple Inc.", instrument.name
  end

  test "skips an already-classified instrument without calling FMP or charging budget" do
    instrument = create_instrument(symbol: "AAPL", sector: "Technology")
    spy = StubProvider.new(series: stock_profile)

    travel_to ET.local(2026, 7, 11, 12) do
      stub_new(PriceProvider::Fmp, spy) do
        Instruments::MetadataJob.perform_now(instrument.id)
      end
      assert_equal 0, spy.call_count
      assert_equal 0, PriceProvider::Budget.new("fmp").requests_today
    end
  end

  test "force: re-fetches even an already-classified instrument (monthly refresh)" do
    instrument = create_instrument(symbol: "AAPL", sector: "Old Sector")
    spy = StubProvider.new(series: stock_profile(sector: "Technology"))

    run_job(instrument, spy, force: true)

    assert_equal 1, spy.call_count
    assert_equal "Technology", instrument.reload.sector
  end

  test "an ETF is stored with a nil sector so it buckets as ETF / Fund" do
    instrument = create_instrument(symbol: "SPY", instrument_type: "etf")

    run_job(instrument, StubProvider.new(series: etf_profile))

    instrument.reload
    assert_nil instrument.sector
    assert_equal "etf", instrument.instrument_type
    assert_equal "ETF / Fund", instrument.sector_label
  end

  test "a missing profile leaves the instrument usable with no crash" do
    instrument = create_instrument(symbol: "NOPE", instrument_type: "stock")

    assert_nothing_raised do
      run_job(instrument, StubProvider.new(series: PriceProvider::Profile.not_found("NOPE")))
    end

    assert_nil instrument.reload.sector
  end

  test "an exhausted FMP budget is a quiet no-op with no retry storm" do
    instrument = create_instrument(symbol: "AAPL", instrument_type: "stock")

    travel_to ET.local(2026, 7, 11, 12) do
      PriceProvider::Budget.new("fmp").charge!(250) # spend the whole daily budget
      assert_no_enqueued_jobs only: Instruments::MetadataJob do
        assert_nothing_raised do
          stub_new(PriceProvider::Fmp, StubProvider.new(series: stock_profile)) do
            Instruments::MetadataJob.perform_now(instrument.id)
          end
        end
      end
    end

    assert_nil instrument.reload.sector
  end

  test "refresh_all fans out a forced refresh per instrument" do
    a = create_instrument(symbol: "AAPL")
    b = create_instrument(symbol: "MSFT")
    clear_enqueued_jobs # drop the one-time create-time metadata enqueues

    Instruments::MetadataJob.refresh_all

    enqueued = enqueued_jobs.select { |j| j["job_class"] == "Instruments::MetadataJob" }
    assert_equal [ a.id, b.id ].sort, enqueued.map { |j| j["arguments"].first }.sort
    assert(enqueued.all? { |j| j["arguments"].last["force"] == true },
           "monthly refresh must force past the already-populated skip")
  end
  # --- directory name enrichment (issues #63/#71) ---------------------------
  #
  # Both of these were shipped untested: removing the enqueue OR its rescue
  # guard failed zero tests, so the guard's own comment ("must never fail an
  # otherwise-successful metadata fetch") was an unverified promise.

  test "a successful fetch schedules directory name enrichment" do
    instrument = create_instrument(symbol: "AAPL", instrument_type: "stock")
    clear_enqueued_jobs

    run_job(instrument, StubProvider.new(series: stock_profile))

    enqueued = enqueued_jobs.select { |j| j["job_class"] == "Directory::EnrichNamesJob" }
    assert_equal 1, enqueued.size,
      "the FMP profile is the only moment a company name enters the system"
  end

  test "a missing profile schedules no enrichment — there is no new name to push" do
    instrument = create_instrument(symbol: "NOPE", instrument_type: "stock")
    clear_enqueued_jobs

    missing = PriceProvider::Profile.new(symbol: "NOPE", name: nil, sector: nil,
                                         industry: nil, instrument_type: nil, found: false)
    run_job(instrument, StubProvider.new(series: missing))

    assert_empty enqueued_jobs.select { |j| j["job_class"] == "Directory::EnrichNamesJob" }
  end

  test "a failing enqueue never loses metadata that was already written" do
    instrument = create_instrument(symbol: "AAPL", instrument_type: "stock")

    # Same define/remove shape as stub_new above — this repo deliberately does
    # not pull in minitest/mock.
    Directory::EnrichNamesJob.define_singleton_method(:perform_later) { |*| raise "queue is down" }
    begin
      assert_nothing_raised do
        run_job(instrument, StubProvider.new(series: stock_profile))
      end
    ensure
      Directory::EnrichNamesJob.singleton_class.send(:remove_method, :perform_later)
    end

    instrument.reload
    assert_equal "Technology", instrument.sector, "the sector write must survive a queue failure"
    assert_equal "Apple Inc.", instrument.name
  end
end
