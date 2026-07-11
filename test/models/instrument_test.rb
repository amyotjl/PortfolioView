require "test_helper"

class InstrumentTest < ActiveSupport::TestCase
  test "normalizes symbol to stripped uppercase" do
    instrument = Instrument.new(symbol: " aapl ")
    assert_equal "AAPL", instrument.symbol
  end

  test "model validation rejects a case-variant duplicate symbol" do
    Instrument.create!(symbol: "AAPL", instrument_type: "stock")
    duplicate = Instrument.new(symbol: "aapl", instrument_type: "stock")

    assert_not duplicate.valid?
    assert duplicate.errors[:symbol].any?, "expected a uniqueness error on symbol"
  end

  test "unique upper(symbol) index rejects a case-variant duplicate at the DB level" do
    Instrument.create!(symbol: "AAPL", instrument_type: "stock")

    # Raw SQL bypasses the model's upcase normalization, so this proves the
    # expression index itself is case-insensitive.
    assert_raises ActiveRecord::RecordNotUnique do
      Instrument.connection.execute(<<~SQL)
        INSERT INTO instruments (symbol, instrument_type, currency, created_at, updated_at)
        VALUES ('aapl', 'stock', 'USD', NOW(), NOW())
      SQL
    end
  end

  test "instrument_type CHECK constraint rejects unknown types at the DB level" do
    error = assert_raises ActiveRecord::StatementInvalid do
      Instrument.connection.execute(<<~SQL)
        INSERT INTO instruments (symbol, instrument_type, currency, created_at, updated_at)
        VALUES ('BND', 'bond', 'USD', NOW(), NOW())
      SQL
    end
    assert_match(/instruments_instrument_type_check/, error.message)
  end

  test "model validation rejects unknown instrument_type" do
    instrument = Instrument.new(symbol: "BND", instrument_type: "bond")

    assert_not instrument.valid?
    assert instrument.errors[:instrument_type].any?
  end
end
