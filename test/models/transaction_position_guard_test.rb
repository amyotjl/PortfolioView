require "test_helper"

# Wiring of Positions::Validator into every transaction mutation, plus the
# series_version cache-buster bump (docs/PLAN.md § Core domain logic /
# § Caching). The API layer (M4) maps these validation errors onto the 422
# error envelope; the model carries the offending date in the message.
class TransactionPositionGuardTest < ActiveSupport::TestCase
  include DomainTestHelper

  EX_DATE = Date.new(2020, 8, 31) # real AAPL 4:1 ex-date

  setup do
    @portfolio = create_portfolio
    @aapl = create_instrument(symbol: "AAPL")
  end

  test "PLAN.md fixture: an oversell is rejected with the offending date in the error" do
    buy!(@portfolio, @aapl, on: Date.new(2026, 1, 5), shares: "10", price: "100")

    oversell = Transaction.new(portfolio: @portfolio, instrument: @aapl, side: "sell",
                               shares: bd("15"), price: bd("110"), executed_on: Date.new(2026, 2, 5))

    assert_not oversell.valid?
    assert_match(/AAPL position negative on 2026-02-05/, oversell.errors[:base].sole)
  end

  test "PLAN.md fixture: a backdated edit that strands a later sell is rejected" do
    purchase = buy!(@portfolio, @aapl, on: Date.new(2026, 1, 5), shares: "10", price: "100")
    sell!(@portfolio, @aapl, on: Date.new(2026, 3, 5), shares: "10", price: "120")

    # Moving the buy after the sell leaves the sell uncovered on its date.
    purchase.executed_on = Date.new(2026, 4, 1)

    assert_not purchase.valid?
    assert_match(/negative on 2026-03-05/, purchase.errors[:base].sole)
  end

  test "shrinking a buy below a later sell is rejected" do
    purchase = buy!(@portfolio, @aapl, on: Date.new(2026, 1, 5), shares: "10", price: "100")
    sell!(@portfolio, @aapl, on: Date.new(2026, 3, 5), shares: "10", price: "120")

    assert_not purchase.update(shares: bd("9"))
    assert_match(/negative on 2026-03-05/, purchase.errors[:base].sole)
  end

  test "PLAN.md fixture: a backdated delete that strands a later sell is rejected" do
    purchase = buy!(@portfolio, @aapl, on: Date.new(2026, 1, 5), shares: "10", price: "100")
    sell!(@portfolio, @aapl, on: Date.new(2026, 3, 5), shares: "10", price: "120")

    assert_not purchase.destroy, "destroy must abort"
    assert_match(/negative on 2026-03-05/, purchase.errors[:base].sole)
    assert Transaction.exists?(purchase.id), "the row must survive the aborted destroy"
    assert_raises(ActiveRecord::RecordNotDestroyed) { purchase.destroy! }
  end

  test "deleting a sell (or a fully offset buy) is allowed" do
    buy!(@portfolio, @aapl, on: Date.new(2026, 1, 5), shares: "10", price: "100")
    disposal = sell!(@portfolio, @aapl, on: Date.new(2026, 3, 5), shares: "10", price: "120")

    assert disposal.destroy
  end

  test "no false positive on the ex-date: selling the post-split count is allowed" do
    split!(@aapl, on: EX_DATE, ratio: "4")
    buy!(@portfolio, @aapl, on: Date.new(2020, 8, 27), shares: "10", price: "400")

    post_split_sell = Transaction.new(portfolio: @portfolio, instrument: @aapl, side: "sell",
                                      shares: bd("40"), price: bd("134"), executed_on: EX_DATE)

    assert_predicate post_split_sell, :valid?
    assert post_split_sell.save
  end

  test "selling beyond the post-split count on the ex-date is rejected" do
    split!(@aapl, on: EX_DATE, ratio: "4")
    buy!(@portfolio, @aapl, on: Date.new(2020, 8, 27), shares: "10", price: "400")

    oversell = Transaction.new(portfolio: @portfolio, instrument: @aapl, side: "sell",
                               shares: bd("41"), price: bd("134"), executed_on: EX_DATE)

    assert_not oversell.valid?
    assert_match(/negative on 2020-08-31/, oversell.errors[:base].sole)
  end

  test "positions are isolated per portfolio" do
    other = create_portfolio(name: "Other")
    buy!(other, @aapl, on: Date.new(2026, 1, 5), shares: "100", price: "100")

    oversell = Transaction.new(portfolio: @portfolio, instrument: @aapl, side: "sell",
                               shares: bd("1"), price: bd("110"), executed_on: Date.new(2026, 2, 5))

    assert_not oversell.valid?, "another portfolio's shares cannot cover this portfolio's sell"
  end

  test "moving a buy to another instrument revalidates the timeline it leaves" do
    msft = create_instrument(symbol: "MSFT")
    purchase = buy!(@portfolio, @aapl, on: Date.new(2026, 1, 5), shares: "10", price: "100")
    sell!(@portfolio, @aapl, on: Date.new(2026, 3, 5), shares: "10", price: "120")

    assert_not purchase.update(instrument: msft)
    assert_match(/AAPL position negative on 2026-03-05/, purchase.errors[:base].sole)
  end

  test "a position-irrelevant update (notes, fees) does not replay and passes" do
    purchase = buy!(@portfolio, @aapl, on: Date.new(2026, 1, 5), shares: "10", price: "100")
    sell!(@portfolio, @aapl, on: Date.new(2026, 3, 5), shares: "10", price: "120")

    assert purchase.update(notes: "cost-basis note", fees: bd("1.50"))
  end

  test "series_version bumps on create, update, and destroy" do
    assert_equal 1, @portfolio.reload.series_version

    purchase = buy!(@portfolio, @aapl, on: Date.new(2026, 1, 5), shares: "10", price: "100")
    assert_equal 2, @portfolio.reload.series_version, "create bumps"

    purchase.update!(notes: "n")
    assert_equal 3, @portfolio.reload.series_version, "update bumps"

    purchase.destroy!
    assert_equal 4, @portfolio.reload.series_version, "destroy bumps"
  end

  test "a rejected mutation does not bump series_version" do
    buy!(@portfolio, @aapl, on: Date.new(2026, 1, 5), shares: "10", price: "100")
    version = @portfolio.reload.series_version

    oversell = Transaction.new(portfolio: @portfolio, instrument: @aapl, side: "sell",
                               shares: bd("15"), price: bd("110"), executed_on: Date.new(2026, 2, 5))

    assert_not oversell.save
    assert_equal version, @portfolio.reload.series_version
  end
end
