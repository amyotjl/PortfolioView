require "test_helper"

# Anchor-based slot advancement (docs/PLAN.md § Recurring materializer /
# § Verification): slots are computed from the anchor, never the previous
# slot, so end-of-month clamping cannot drift.
class RecurringTransactionScheduleTest < ActiveSupport::TestCase
  def rule(frequency:, anchor_on:)
    RecurringTransaction.new(frequency: frequency, anchor_on: anchor_on)
  end

  test "PLAN.md fixture: Jan-31 monthly -> Feb-28 -> Mar-31 (clamped, then back to the 31st — no drift)" do
    monthly = rule(frequency: "monthly", anchor_on: Date.new(2026, 1, 31))

    assert_equal Date.new(2026, 2, 28), monthly.next_slot_after(Date.new(2026, 1, 31))
    assert_equal Date.new(2026, 3, 31), monthly.next_slot_after(Date.new(2026, 2, 28)),
                 "advancing FROM the clamped Feb-28 must return to the anchor's 31st"
    assert_equal Date.new(2026, 4, 30), monthly.next_slot_after(Date.new(2026, 3, 31))
  end

  test "monthly clamping lands on Feb-29 in a leap year" do
    monthly = rule(frequency: "monthly", anchor_on: Date.new(2024, 1, 31))

    assert_equal Date.new(2024, 2, 29), monthly.next_slot_after(Date.new(2024, 1, 31))
  end

  test "quarterly steps 3 anchor-months at a time with clamping" do
    quarterly = rule(frequency: "quarterly", anchor_on: Date.new(2026, 1, 31))

    assert_equal Date.new(2026, 4, 30), quarterly.next_slot_after(Date.new(2026, 1, 31))
    assert_equal Date.new(2026, 7, 31), quarterly.next_slot_after(Date.new(2026, 4, 30))
    assert_equal Date.new(2026, 10, 31), quarterly.next_slot_after(Date.new(2026, 7, 31))
  end

  test "weekly and biweekly step in whole anchor-relative weeks" do
    weekly = rule(frequency: "weekly", anchor_on: Date.new(2026, 1, 5)) # a Monday
    assert_equal Date.new(2026, 1, 12), weekly.next_slot_after(Date.new(2026, 1, 5))
    assert_equal Date.new(2026, 1, 12), weekly.next_slot_after(Date.new(2026, 1, 8)),
                 "a mid-week date advances to the next anchor-aligned slot"

    biweekly = rule(frequency: "biweekly", anchor_on: Date.new(2026, 1, 5))
    assert_equal Date.new(2026, 1, 19), biweekly.next_slot_after(Date.new(2026, 1, 5))
    assert_equal Date.new(2026, 2, 2), biweekly.next_slot_after(Date.new(2026, 1, 19))
  end

  test "a date before the anchor advances to the anchor itself" do
    monthly = rule(frequency: "monthly", anchor_on: Date.new(2026, 6, 30))

    assert_equal Date.new(2026, 6, 30), monthly.next_slot_after(Date.new(2026, 1, 1))
  end

  test "first_slot_on_or_after returns the date itself when it is a slot" do
    monthly = rule(frequency: "monthly", anchor_on: Date.new(2026, 1, 31))

    assert_equal Date.new(2026, 2, 28), monthly.first_slot_on_or_after(Date.new(2026, 2, 28))
    assert_equal Date.new(2026, 3, 31), monthly.first_slot_on_or_after(Date.new(2026, 3, 1))
  end

  test "catch-up across many missed months stays anchored (no drift accumulation)" do
    monthly = rule(frequency: "monthly", anchor_on: Date.new(2026, 1, 31))

    slot = Date.new(2026, 1, 31)
    5.times { slot = monthly.next_slot_after(slot) }

    assert_equal Date.new(2026, 6, 30), slot, "Jan-31 + 5 anchor months = Jun-30 (clamped), not a drifted 28th"
  end
end
