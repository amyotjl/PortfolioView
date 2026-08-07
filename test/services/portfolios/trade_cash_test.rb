require "test_helper"

# The one home for the signed-external-cash-for-a-trade formula (issue #80),
# extracted from two hand-copied implementations. A sign error here is silent
# money, and a rounding error here is the pennies the whole cash feature exists
# to eliminate.
class Portfolios::TradeCashTest < ActiveSupport::TestCase
  include DomainTestHelper

  Trade = Data.define(:side, :shares, :price, :fees)

  def trade(side:, shares:, price:, fees: "0")
    Trade.new(side: side, shares: bd(shares), price: bd(price), fees: bd(fees))
  end

  # --- the formula ---

  test "a buy pushes cost PLUS fees into the portfolio" do
    assert_equal bd("1005"), Portfolios::TradeCash.for(trade(side: "buy", shares: "10", price: "100", fees: "5"))
  end

  test "a sell withdraws proceeds NET of fees, signed negative" do
    assert_equal bd("-597"), Portfolios::TradeCash.for(trade(side: "sell", shares: "5", price: "120", fees: "3"))
  end

  test "dollars reads the same money in the direction's own sign" do
    buy  = trade(side: "buy",  shares: "10", price: "100", fees: "5")
    sell = trade(side: "sell", shares: "5",  price: "120", fees: "3")

    assert_equal bd("1005"), Portfolios::TradeCash.dollars(buy)
    assert_equal bd("597"),  Portfolios::TradeCash.dollars(sell), "the benchmark matches +$597 of withdrawal"
  end

  # Not `.for(tx).abs`: a sell whose fees swallow its proceeds must stay negative
  # so Benchmarks::Simulation's `next unless dollars.positive?` still skips it.
  test "dollars stays NEGATIVE for a sell whose fees exceed its proceeds" do
    fee_eaten = trade(side: "sell", shares: "1", price: "10", fees: "25")

    assert_equal bd("-15"), Portfolios::TradeCash.dollars(fee_eaten)
    assert_predicate Portfolios::TradeCash.dollars(fee_eaten), :negative?
  end

  # --- per-transaction cent rounding ---

  test "each trade's cash effect is rounded to the CENT, not left at 14 dp" do
    # 0.33333333 x 10.005 = 3.33499999665 -> 3.33
    tx = trade(side: "buy", shares: "0.33333333", price: "10.005")

    amount = Portfolios::TradeCash.for(tx)

    assert_equal bd("3.33"), amount
    assert_equal 2, amount.scale, "a cash movement is denominated in whole cents"
  end

  test "the rounding is applied to the WHOLE movement, fees included" do
    # 3 x 33.333333 = 99.999999, + 0.01 fees = 100.009999 -> 100.01
    assert_equal bd("100.01"),
                 Portfolios::TradeCash.for(trade(side: "buy", shares: "3", price: "33.333333", fees: "0.01"))
  end

  test "MoneyMath.round_to_cents rounds half up and rejects Floats like the rest of the money math" do
    assert_equal bd("1.24"), MoneyMath.round_to_cents(bd("1.235"))
    assert_equal bd("-1.24"), MoneyMath.round_to_cents(bd("-1.235"))
    assert_equal bd("0.01"), MoneyMath.round_to_cents("0.005")
    assert_raises(TypeError) { MoneyMath.round_to_cents(1.235) }
  end

  test "a Float share count cannot enter the trade-cash formula" do
    assert_raises TypeError do
      Portfolios::TradeCash.for(Data.define(:side, :shares, :price, :fees)
                                   .new(side: "buy", shares: 10.0, price: bd("100"), fees: bd("0")))
    end
  end
end
