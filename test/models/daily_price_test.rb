require "test_helper"

class DailyPriceTest < ActiveSupport::TestCase
  setup do
    @instrument = Instrument.create!(symbol: "AAPL", instrument_type: "stock")
  end

  def price_row(overrides = {})
    {
      instrument_id: @instrument.id,
      date: Date.new(2026, 7, 10),
      open: "100.5", high: "101.25", low: "99.75", close: "100.0",
      volume: 1_000_000,
      source: "tiingo"
    }.merge(overrides)
  end

  test "upsert_all against UNIQUE (instrument_id, date) is conflict-safe" do
    DailyPrice.upsert_all([price_row], unique_by: [:instrument_id, :date])
    DailyPrice.upsert_all([price_row(close: "102.5")], unique_by: [:instrument_id, :date])

    rows = DailyPrice.where(instrument_id: @instrument.id, date: Date.new(2026, 7, 10))
    assert_equal 1, rows.count, "upserting the same (instrument_id, date) twice must leave one row"
    assert_equal BigDecimal("102.5"), rows.first.close
  end

  test "UNIQUE (instrument_id, date) rejects a duplicate plain insert" do
    DailyPrice.create!(price_row)

    assert_raises ActiveRecord::RecordNotUnique do
      DailyPrice.new(price_row).save!(validate: false)
    end
  end

  test "CHECK rejects high < low at the DB level" do
    error = assert_raises ActiveRecord::StatementInvalid do
      DailyPrice.new(price_row(high: "99.0", low: "100.0")).save!(validate: false)
    end
    assert_match(/daily_prices_high_low_check/, error.message)
  end

  test "CHECK rejects low <= 0 at the DB level" do
    error = assert_raises ActiveRecord::StatementInvalid do
      DailyPrice.new(price_row(low: "0", high: "1")).save!(validate: false)
    end
    assert_match(/daily_prices_high_low_check/, error.message)
  end

  test "model validation mirrors the high >= low check" do
    price = DailyPrice.new(price_row(high: "99.0", low: "100.0"))

    assert_not price.valid?
    assert price.errors[:high].any?
  end

  test "deleting an instrument cascades its price rows" do
    DailyPrice.create!(price_row)

    @instrument.destroy!

    assert_equal 0, DailyPrice.where(instrument_id: @instrument.id).count
  end
end
