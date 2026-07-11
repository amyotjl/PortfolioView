require "test_helper"

class SplitEventTest < ActiveSupport::TestCase
  setup do
    @instrument = Instrument.create!(symbol: "AAPL", instrument_type: "stock")
  end

  test "UNIQUE (instrument_id, ex_date) rejects duplicates at the DB level" do
    SplitEvent.create!(instrument: @instrument, ex_date: Date.new(2020, 8, 31), ratio: 4)

    assert_raises ActiveRecord::RecordNotUnique do
      SplitEvent.new(instrument: @instrument, ex_date: Date.new(2020, 8, 31), ratio: 4)
                .save!(validate: false)
    end
  end

  test "upsert_all against UNIQUE (instrument_id, ex_date) is conflict-safe" do
    row = { instrument_id: @instrument.id, ex_date: Date.new(2020, 8, 31), ratio: 4 }

    SplitEvent.upsert_all([row], unique_by: [:instrument_id, :ex_date])
    SplitEvent.upsert_all([row], unique_by: [:instrument_id, :ex_date])

    assert_equal 1, SplitEvent.where(instrument_id: @instrument.id).count
  end

  test "CHECK rejects a non-positive ratio at the DB level" do
    error = assert_raises ActiveRecord::StatementInvalid do
      SplitEvent.new(instrument: @instrument, ex_date: Date.new(2020, 8, 31), ratio: 0)
                .save!(validate: false)
    end
    assert_match(/split_events_ratio_positive/, error.message)
  end

  test "ratio stores Tiingo's decimal splitFactor exactly" do
    split = SplitEvent.create!(instrument: @instrument, ex_date: Date.new(2020, 8, 31),
                               ratio: "1.111111")
    assert_equal BigDecimal("1.111111"), split.reload.ratio
  end
end
