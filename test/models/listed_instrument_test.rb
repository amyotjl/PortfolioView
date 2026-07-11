require "test_helper"

class ListedInstrumentTest < ActiveSupport::TestCase
  test "unique (symbol, exchange) index rejects duplicates at the DB level" do
    ListedInstrument.create!(symbol: "AAPL", exchange: "NASDAQ")

    assert_raises ActiveRecord::RecordNotUnique do
      ListedInstrument.new(symbol: "AAPL", exchange: "NASDAQ").save!(validate: false)
    end
  end

  test "NULLS NOT DISTINCT: two rows with the same symbol and NULL exchange are rejected" do
    ListedInstrument.create!(symbol: "AAPL", exchange: nil)

    assert_raises ActiveRecord::RecordNotUnique do
      ListedInstrument.new(symbol: "AAPL", exchange: nil).save!(validate: false)
    end
  end

  test "same symbol on a different exchange is allowed" do
    ListedInstrument.create!(symbol: "AAPL", exchange: "NASDAQ")

    assert_nothing_raised do
      ListedInstrument.create!(symbol: "AAPL", exchange: "LSE")
    end
  end
end
