require "test_helper"

class BenchmarkTest < ActiveSupport::TestCase
  setup do
    @instrument = Instrument.create!(symbol: "SPY", instrument_type: "etf")
    @benchmark = Benchmark.create!(instrument: @instrument, name: "S&P 500 (SPY)")
  end

  test "the model class is our ActiveRecord model, not stdlib Benchmark" do
    assert_operator Benchmark, :<, ApplicationRecord
  end

  test "FK RESTRICT: an instrument backing a benchmark cannot be deleted at the DB level" do
    # `delete` bypasses the model's restrict_with_error callback, proving
    # the database constraint itself.
    assert_raises ActiveRecord::InvalidForeignKey do
      @instrument.delete
    end
  end

  test "model mirror: destroying an instrument backing a benchmark is refused with an error" do
    assert_not @instrument.destroy
    assert @instrument.errors[:base].any?
  end

  test "one benchmark per instrument, enforced by the unique FK index" do
    assert_raises ActiveRecord::RecordNotUnique do
      Benchmark.new(instrument: @instrument, name: "Duplicate SPY").save!(validate: false)
    end
  end

  test "benchmark names are unique at the DB level" do
    other = Instrument.create!(symbol: "VOO", instrument_type: "etf")

    assert_raises ActiveRecord::RecordNotUnique do
      Benchmark.new(instrument: other, name: "S&P 500 (SPY)").save!(validate: false)
    end
  end
end
