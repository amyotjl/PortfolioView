require "test_helper"

class Positions::ValidatorTest < ActiveSupport::TestCase
  include DomainTestHelper

  setup { @aapl = create_instrument(symbol: "AAPL") }

  def entry(executed_on, side, shares)
    Positions::Validator::Entry.new(executed_on: executed_on, side: side, shares: bd(shares))
  end

  def validate(entries, instrument: @aapl, **opts)
    Positions::Validator.call(instrument_id: instrument.id, transactions: entries, **opts)
  end

  test "a fully covered sell is valid" do
    result = validate([
      entry(Date.new(2026, 1, 5), "buy", "10"),
      entry(Date.new(2026, 2, 5), "sell", "10")
    ])

    assert_predicate result, :valid?
    assert_nil result.first_offending_date
  end

  test "an oversell is invalid and names the sell date" do
    result = validate([
      entry(Date.new(2026, 1, 5), "buy", "10"),
      entry(Date.new(2026, 2, 5), "sell", "10.00000001")
    ])

    assert_not result.valid?
    assert_equal Date.new(2026, 2, 5), result.first_offending_date
  end

  test "a mid-history dip is caught even when the final position is positive" do
    result = validate([
      entry(Date.new(2026, 1, 5), "buy", "10"),
      entry(Date.new(2026, 2, 5), "sell", "15"),
      entry(Date.new(2026, 3, 5), "buy", "10")
    ])

    assert_not result.valid?
    assert_equal Date.new(2026, 2, 5), result.first_offending_date, "the FIRST offending date is named"
  end

  test "selling the post-split share count on the ex-date is allowed (split applies at start of day)" do
    split!(@aapl, on: Date.new(2020, 8, 31), ratio: "4")

    result = validate([
      entry(Date.new(2020, 8, 27), "buy", "10"),
      entry(Date.new(2020, 8, 31), "sell", "40")
    ])

    assert_predicate result, :valid?
  end

  test "selling one share beyond the post-split count on the ex-date is rejected" do
    split!(@aapl, on: Date.new(2020, 8, 31), ratio: "4")

    result = validate([
      entry(Date.new(2020, 8, 27), "buy", "10"),
      entry(Date.new(2020, 8, 31), "sell", "41")
    ])

    assert_not result.valid?
    assert_equal Date.new(2020, 8, 31), result.first_offending_date
  end

  test "a pre-split sell is judged in the pre-split basis" do
    split!(@aapl, on: Date.new(2020, 8, 31), ratio: "4")

    result = validate([
      entry(Date.new(2020, 8, 27), "buy", "10"),
      entry(Date.new(2020, 8, 28), "sell", "40") # before the ex-date: only 10 exist
    ])

    assert_not result.valid?
    assert_equal Date.new(2020, 8, 28), result.first_offending_date
  end

  test "a weekend-dated oversell is caught (event dates, not just trading days)" do
    result = validate([
      entry(Date.new(2026, 7, 6), "buy", "5"),
      entry(Date.new(2026, 7, 11), "sell", "6") # Saturday
    ])

    assert_not result.valid?
    assert_equal Date.new(2026, 7, 11), result.first_offending_date
  end

  test "same-day buy and sell net out at end of day" do
    result = validate([
      entry(Date.new(2026, 1, 5), "sell", "10"),
      entry(Date.new(2026, 1, 5), "buy", "10")
    ])

    assert_predicate result, :valid?, "EOD granularity: the day's net position is the invariant"
  end

  test "splits are injectable" do
    result = validate(
      [ entry(Date.new(2026, 1, 5), "buy", "10"), entry(Date.new(2026, 1, 8), "sell", "20") ],
      splits: [ [ Date.new(2026, 1, 6), bd("2") ] ]
    )

    assert_predicate result, :valid?
  end

  test "an empty transaction set is valid" do
    assert_predicate validate([]), :valid?
  end

  test "Float shares raise TypeError" do
    assert_raises TypeError do
      validate([ Positions::Validator::Entry.new(executed_on: Date.new(2026, 1, 5), side: "buy", shares: 10.0) ])
    end
  end
end
