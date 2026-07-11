require "test_helper"

class PortfolioTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email_address: "portfolio-owner@example.com", password: "password")
  end

  test "series_version defaults to 1" do
    portfolio = Portfolio.create!(user: @user, name: "Retirement")
    assert_equal 1, portfolio.reload.series_version
  end

  test "UNIQUE (user_id, name) rejects a duplicate name for the same user at the DB level" do
    Portfolio.create!(user: @user, name: "Retirement")

    assert_raises ActiveRecord::RecordNotUnique do
      Portfolio.new(user: @user, name: "Retirement").save!(validate: false)
    end
  end

  test "the same portfolio name is allowed for a different user" do
    Portfolio.create!(user: @user, name: "Retirement")
    other = User.create!(email_address: "other-owner@example.com", password: "password")

    assert_nothing_raised do
      Portfolio.create!(user: other, name: "Retirement")
    end
  end

  test "model validation mirrors the per-user name uniqueness" do
    Portfolio.create!(user: @user, name: "Retirement")
    duplicate = Portfolio.new(user: @user, name: "Retirement")

    assert_not duplicate.valid?
    assert duplicate.errors[:name].any?
  end

  test "FK CASCADE: deleting a user removes their portfolios at the DB level" do
    portfolio = Portfolio.create!(user: @user, name: "Retirement")

    @user.delete

    assert_not Portfolio.exists?(portfolio.id)
  end

  test "FK RESTRICT: a benchmark referenced by a portfolio cannot be deleted at the DB level" do
    instrument = Instrument.create!(symbol: "SPY", instrument_type: "etf")
    benchmark = Benchmark.create!(instrument: instrument, name: "S&P 500 (SPY)")
    Portfolio.create!(user: @user, name: "Retirement", benchmark: benchmark)

    assert_raises ActiveRecord::InvalidForeignKey do
      benchmark.delete
    end
  end
end
