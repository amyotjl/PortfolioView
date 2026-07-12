require "test_helper"

class Trading::CalendarTest < ActiveSupport::TestCase
  include DomainTestHelper

  # 2026-07: 4th falls on a Saturday, observed Friday 2026-07-03 — model it as
  # a holiday by omitting the SPY row.
  HOLIDAY = Date.new(2026, 7, 3)

  setup do
    create_trading_days(Date.new(2026, 6, 29), Date.new(2026, 7, 10), except: [ HOLIDAY ])
  end

  test "days_between returns only dates with a SPY price row, ascending" do
    days = Trading::Calendar.days_between(Date.new(2026, 6, 29), Date.new(2026, 7, 10))

    assert_equal days.sort, days
    assert_includes days, Date.new(2026, 6, 30)
    assert_not_includes days, Date.new(2026, 7, 4), "Saturday is not a trading day"
    assert_not_includes days, HOLIDAY, "a holiday (no SPY row) is not a trading day"
    assert_equal 9, days.size # 10 weekdays minus the holiday
  end

  test "first_day_on_or_after skips a weekend to Monday" do
    assert_equal Date.new(2026, 7, 6), Trading::Calendar.first_day_on_or_after(Date.new(2026, 7, 4))
  end

  test "first_day_on_or_after returns the date itself when it trades" do
    assert_equal Date.new(2026, 7, 7), Trading::Calendar.first_day_on_or_after(Date.new(2026, 7, 7))
  end

  test "first_day_on_or_after skips a holiday" do
    assert_equal Date.new(2026, 7, 6), Trading::Calendar.first_day_on_or_after(HOLIDAY)
  end

  test "first_day_on_or_after is nil beyond the price cache" do
    assert_nil Trading::Calendar.first_day_on_or_after(Date.new(2026, 7, 11))
  end

  test "last_day is the most recent cached trading day" do
    assert_equal Date.new(2026, 7, 10), Trading::Calendar.last_day
  end

  test "today is computed in America/New_York, not the host clock" do
    # 02:00 UTC on July 13 is still 22:00 on July 12 in New York.
    travel_to Time.utc(2026, 7, 13, 2, 0) do
      assert_equal Date.new(2026, 7, 12), Trading::Calendar.today
    end
  end
end
