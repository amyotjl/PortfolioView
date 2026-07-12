# Shared builders for the domain-service tests (backlog #018-#023): the money
# math runs against a synthetic trading calendar (SPY daily_prices rows ARE the
# calendar — docs/PLAN.md § Trading calendar & time), hand-seeded unadjusted
# prices, and split events.
#
# All numeric inputs are given as Strings or Integers and coerced through
# BigDecimal — never Float — so the fixtures themselves respect the invariant
# the services enforce.
module DomainTestHelper
  def bd(value) = BigDecimal(value.to_s)

  def create_portfolio(name: "Main", user: users(:one), benchmark: nil)
    Portfolio.create!(user: user, name: name, benchmark: benchmark)
  end

  # find_or_create so tests can reference SPY both as the calendar and as a
  # benchmark instrument without duplicate-symbol collisions.
  def create_instrument(symbol:, instrument_type: "stock")
    Instrument.find_by(symbol: symbol.upcase) ||
      Instrument.create!(symbol: symbol, instrument_type: instrument_type, currency: "USD")
  end

  def weekdays_between(from, to)
    (from..to).reject { |d| d.saturday? || d.sunday? }
  end

  # Seed the trading calendar: SPY rows for every weekday in from..to except
  # the given holiday dates. Returns the SPY instrument. `closes` optionally
  # maps specific dates to SPY closes (for benchmark-simulation tests where
  # SPY is also the traded benchmark); other days get a flat 100.
  def create_trading_days(from, to, except: [], closes: {})
    spy = create_instrument(symbol: "SPY", instrument_type: "etf")
    dates = weekdays_between(from, to) - Array(except)
    seed_prices(spy, dates.index_with { |d| closes[d] || 100 })
    spy
  end

  # Seed unadjusted daily prices. `quotes` maps date => close (o/h/l collapse
  # to the close) or date => [open, high, low, close].
  def seed_prices(instrument, quotes)
    rows = quotes.map do |date, quote|
      open, high, low, close = quote.is_a?(Array) ? quote : [ quote, quote, quote, quote ]
      { instrument_id: instrument.id, date: date,
        open: bd(open), high: bd(high), low: bd(low), close: bd(close),
        volume: 0, source: "test" }
    end
    DailyPrice.upsert_all(rows, unique_by: %i[instrument_id date], record_timestamps: true) if rows.any?
  end

  def buy!(portfolio, instrument, on:, shares:, price:, fees: "0", kind: "normal", **attrs)
    Transaction.create!(portfolio: portfolio, instrument: instrument, side: "buy", kind: kind,
                        shares: bd(shares), price: bd(price), fees: bd(fees),
                        executed_on: on, **attrs)
  end

  def sell!(portfolio, instrument, on:, shares:, price:, fees: "0", kind: "normal", **attrs)
    Transaction.create!(portfolio: portfolio, instrument: instrument, side: "sell", kind: kind,
                        shares: bd(shares), price: bd(price), fees: bd(fees),
                        executed_on: on, **attrs)
  end

  def split!(instrument, on:, ratio:)
    SplitEvent.create!(instrument: instrument, ex_date: on, ratio: bd(ratio))
  end

  # Count the real SQL queries issued inside the block (schema loads,
  # transaction bookkeeping, and query-cache hits excluded) — backs the
  # Holdings::Calculator "exactly 3 queries, no N+1" contract.
  def count_queries(&block)
    count = 0
    counter = lambda do |_name, _start, _finish, _id, payload|
      next if payload[:cached]
      next if %w[SCHEMA TRANSACTION CACHE].include?(payload[:name].to_s)
      next if payload[:sql].match?(/\A(?:BEGIN|COMMIT|SAVEPOINT|RELEASE|SET)\b/i)
      count += 1
    end
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record", &block)
    count
  end
end
