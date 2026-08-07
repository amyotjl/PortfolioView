require "test_helper"

class DividendEventTest < ActiveSupport::TestCase
  setup do
    @instrument = Instrument.create!(symbol: "AAPL", instrument_type: "stock")
  end

  test "UNIQUE (instrument_id, ex_date) rejects duplicates at the DB level" do
    DividendEvent.create!(instrument: @instrument, ex_date: Date.new(2026, 5, 12),
                          cash_per_share: "0.26")

    assert_raises ActiveRecord::RecordNotUnique do
      DividendEvent.new(instrument: @instrument, ex_date: Date.new(2026, 5, 12),
                        cash_per_share: "0.26").save!(validate: false)
    end
  end

  test "upsert_all against UNIQUE (instrument_id, ex_date) is conflict-safe" do
    row = { instrument_id: @instrument.id, ex_date: Date.new(2026, 5, 12), cash_per_share: "0.26" }

    DividendEvent.upsert_all([ row ], unique_by: [ :instrument_id, :ex_date ])
    DividendEvent.upsert_all([ row.merge(cash_per_share: "0.27") ], unique_by: [ :instrument_id, :ex_date ])

    rows = DividendEvent.where(instrument_id: @instrument.id)
    assert_equal 1, rows.count
    assert_equal BigDecimal("0.27"), rows.first.cash_per_share
  end

  test "CHECK rejects a non-positive cash_per_share at the DB level" do
    error = assert_raises ActiveRecord::StatementInvalid do
      DividendEvent.new(instrument: @instrument, ex_date: Date.new(2026, 5, 12),
                        cash_per_share: 0).save!(validate: false)
    end
    assert_match(/dividend_events_cash_per_share_positive/, error.message)
  end
end
