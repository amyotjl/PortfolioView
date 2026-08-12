module Demo
  # Builds the demo account the README screenshots are taken from.
  #
  # WHY THIS IS NOT A FIXTURE FILE: every trade is priced from the real
  # `daily_prices` row for its date, so the resulting charts, returns and
  # benchmark edge are what the app genuinely computes over real market history
  # — a hand-written price would show a portfolio the market never produced, and
  # any drawdown, gap or split in the screenshots would be fiction. The cost is
  # that the symbols must already be backfilled; `call` fails loudly (never
  # silently thins the plan) when one is not.
  #
  # Everything is DETERMINISTIC — no randomness anywhere — so re-running it
  # after a data refresh reproduces the same screenshots. Contribution schedules
  # are fixed dollar amounts on fixed dates, and the monthly buy picks whatever
  # is furthest below its target weight.
  #
  #   bin/rails demo:seed          # idempotent: rebuilds the demo user's data
  #
  # The seeder replays the split and dividend history itself while stepping
  # forward, because both change what a later month buys: an unadjusted
  # pre-split close (NVDA traded near $1,200 before its 2024 10:1) values the
  # position wrongly on the next rebalance if the split is ignored, and dividend
  # cash is a real part of what the next contribution has to spend.
  class Seeder
    EMAIL = "demo@portfolioview.app".freeze
    PASSWORD = "demo-portfolio-2026".freeze

    # Fraction of available cash a monthly contribution deploys. Deliberately
    # under 1.0: a real account keeps an idle remainder, and a portfolio that is
    # always exactly 100% invested makes the cash series — a #80 feature the
    # dashboard draws — a flat zero line.
    INVEST_RATIO = 0.94

    # How many positions one contribution buys. Buying every underweight name
    # every month produces a ledger of 11 tiny odd-lot trades per month, which
    # is not what a real statement looks like.
    BUYS_PER_CONTRIBUTION = 3

    # Annualized rate for the quarterly cash-sweep interest credit.
    CASH_INTEREST_RATE = 0.0225

    # US non-resident withholding on dividends, applied only to the plan that
    # models a non-registered account.
    WITHHOLDING_RATE = 0.15

    Plan = Struct.new(
      :name, :benchmark, :calendar, :opening, :monthly, :first_month, :targets,
      :withhold_tax, :sweep_interest, :events, :recurring, keyword_init: true
    )

    PLANS = [
      Plan.new(
        name: "Core Growth",
        benchmark: "SPY",
        calendar: "SPY",
        opening: 25_000,
        monthly: 2_500,
        first_month: Date.new(2023, 1, 1),
        targets: {
          "MSFT" => 0.14, "AAPL" => 0.12, "NVDA" => 0.11, "AMZN" => 0.10,
          "GOOGL" => 0.09, "VTI" => 0.10, "V" => 0.08, "COST" => 0.08,
          "JPM" => 0.08, "UNH" => 0.05, "CAT" => 0.05
        },
        withhold_tax: false,
        sweep_interest: true,
        events: [
          { on: Date.new(2024, 3, 14), action: :sell, symbol: "NVDA", fraction: 0.25,
            notes: "Trimmed after the run-up — position had drifted well above target." },
          # A withdrawal has to be FUNDED, on its own date, by a sell — a
          # brokerage account does not keep five figures of idle cash, so
          # withdrawing against the contribution float would just overdraw it
          # (and `withdraw` raises rather than let that pass silently).
          { on: Date.new(2025, 6, 10), action: :sell, symbol: "AAPL", fraction: 0.30,
            notes: "Raising cash for a planned withdrawal." },
          { on: Date.new(2025, 6, 12), action: :withdraw, amount: 6_000,
            notes: "Withdrawal — vehicle down payment." },
          { on: Date.new(2025, 11, 4), action: :deposit, amount: 10_000,
            notes: "Year-end bonus contribution." }
        ],
        recurring: [
          { symbol: "VTI", dollars: 500, frequency: "monthly", day: 15 },
          { symbol: "MSFT", dollars: 400, frequency: "quarterly", day: 20 }
        ]
      ),
      Plan.new(
        name: "Dividend Income",
        benchmark: "VTI",
        calendar: "SPY",
        opening: 12_000,
        monthly: 800,
        first_month: Date.new(2024, 1, 1),
        targets: {
          "JNJ" => 0.18, "KO" => 0.17, "PG" => 0.17, "XOM" => 0.16,
          "JPM" => 0.16, "HD" => 0.16
        },
        # Non-registered account: US dividends arrive net of withholding, which
        # is what makes this plan exercise the internal cash kinds (`tax`) that
        # must never count as a contribution.
        withhold_tax: true,
        sweep_interest: true,
        events: [],
        recurring: [ { symbol: "KO", dollars: 250, frequency: "monthly", day: 8 } ]
      ),
      Plan.new(
        name: "TFSA — Canadian Core",
        # No benchmark: the curated list is USD (SPY/VTI/QQQ) and there is no FX
        # in v1, so comparing a CAD book against a USD index would print a
        # confidently wrong edge. Left null on purpose.
        benchmark: nil,
        calendar: "VFV.TO",
        opening: 8_000,
        monthly: 600,
        first_month: Date.new(2022, 6, 1),
        targets: { "VFV.TO" => 0.35, "VEQT.TO" => 0.30, "XEI.TO" => 0.20, "VDY.TO" => 0.15 },
        withhold_tax: false,
        sweep_interest: true,
        events: [],
        recurring: [ { symbol: "VEQT.TO", dollars: 300, frequency: "biweekly", day: 6 } ]
      )
    ].freeze

    def self.call(...) = new(...).call

    def initialize(today: Trading::Calendar.today, io: $stdout)
      @today = today
      @io = io
    end

    def call
      user = reset_user
      PLANS.each { |plan| build(plan, user) }
      user
    end

    private

    attr_reader :today, :io

    # Idempotent by REBUILD rather than by upsert: the ledger is a sequence
    # whose every row depends on the running position, so a partially-present
    # portfolio cannot be topped up correctly. Portfolios cascade to their
    # transactions, cash rows and recurring rules at the DB level.
    def reset_user
      user = User.find_or_initialize_by(email_address: EMAIL)
      user.password = PASSWORD
      user.save!
      count = user.portfolios.count
      user.portfolios.destroy_all
      say "user #{EMAIL} ready (cleared #{count} existing portfolio(s))"
      user
    end

    def build(plan, user)
      state = State.new(plan: plan, instruments: instruments_for(plan), calendar: calendar_for(plan))
      portfolio = user.portfolios.create!(name: plan.name, benchmark: benchmark_for(plan))
      state.portfolio = portfolio

      open_account(state)
      timeline(plan).each { |action| apply(action, state) }
      create_recurring(state)

      say format("%-22s %4d trades  %3d cash rows  %s invested  cash %s",
                 plan.name, portfolio.transactions.count, portfolio.cash_transactions.count,
                 money(state.invested), money(state.cash))
    end

    # --- timeline ------------------------------------------------------------

    # One flat, date-sorted list of everything that happens. Scripted events are
    # merged into the monthly contribution schedule rather than special-cased
    # afterwards, so a sell's proceeds are available to the next contribution and
    # a withdrawal genuinely reduces what it can buy — the ordering IS the model.
    def timeline(plan)
      months = []
      month = plan.first_month
      while month <= today.beginning_of_month
        months << { on: month.change(day: 3), action: :contribute }
        month = month >> 1
      end
      (months + plan.events).sort_by { |action| [ action[:on], action[:action] == :contribute ? 1 : 0 ] }
    end

    def apply(action, state)
      on = state.calendar.trading_day_on_or_after(action[:on])
      return if on.nil? || on > last_priced_day(state)

      advance_to(state, on)

      case action[:action]
      when :contribute then contribute(state, on)
      when :deposit    then deposit(state, on, action[:amount], action[:notes])
      when :withdraw   then withdraw(state, on, action[:amount], action[:notes])
      when :sell       then sell(state, on, action[:symbol], action[:fraction], action[:notes])
      end
    end

    # Cross the corporate-action and interest events that fall between the last
    # action and this one. Dividends are computed on the position held while the
    # event happened (i.e. before this date's buys), which is why this runs
    # first and not at the end of a step.
    def advance_to(state, on)
      from = state.cursor
      return if from && from >= on

      state.instruments.each_value do |instrument|
        credit_dividends(state, instrument, from, on)
        apply_splits(state, instrument, from, on)
      end
      credit_interest(state, from, on)
      state.cursor = on
    end

    def open_account(state)
      on = state.calendar.trading_day_on_or_after(state.plan.first_month.change(day: 3))
      state.cursor = on
      deposit(state, on, state.plan.opening, "Opening transfer from external account.")
      invest(state, on)
    end

    def contribute(state, on)
      deposit(state, on, state.plan.monthly, "Monthly contribution.")
      invest(state, on)
    end

    # --- cash ----------------------------------------------------------------

    def deposit(state, on, amount, notes)
      record_cash(state, on, "deposit", amount.to_d, notes)
    end

    # Overdrawing is legal in the DOMAIN (a negative balance is reported, never
    # rejected — #80) but it is never what a scripted demo event intends: it
    # would raise the dashboard's negative-cash warning over what is supposed to
    # be an ordinary transfer out. So the seeder refuses, and names the shortfall
    # so the plan can be corrected — a clamp here would silently withdraw a
    # different amount than the plan says.
    def withdraw(state, on, amount, notes)
      amount = amount.to_d
      if amount > state.cash
        raise "#{state.plan.name}: withdrawal of #{money(amount)} on #{on} exceeds the " \
              "#{money(state.cash)} available — fund it with a sell first, or reduce it"
      end
      record_cash(state, on, "withdrawal", -amount, notes)
    end

    def credit_dividends(state, instrument, from, on)
      dividends(instrument).each do |ex_date, per_share|
        next unless in_window?(ex_date, from, on)
        shares = state.shares.fetch(instrument.symbol, 0.to_d)
        next if shares.zero?

        gross = round_money(shares * per_share)
        next if gross <= 0

        record_cash(state, ex_date, "dividend_cash", gross,
                    "#{instrument.symbol} dividend — #{shares.to_i} shares.")
        next unless state.plan.withhold_tax

        withheld = round_money(gross * WITHHOLDING_RATE.to_d)
        next if withheld <= 0

        record_cash(state, ex_date, "tax", -withheld,
                    "US withholding tax on #{instrument.symbol} dividend.")
      end
    end

    # Quarterly cash-sweep interest on the balance actually sitting idle. Not
    # accrued daily: a brokerage credits a single monthly/quarterly line, and a
    # daily accrual would bury the ledger under hundreds of cent-sized rows.
    def credit_interest(state, from, on)
      return unless state.plan.sweep_interest
      return if from.nil?

      quarters_between(from, on).each do |quarter_end|
        next if state.cash < 100
        amount = round_money(state.cash * (CASH_INTEREST_RATE / 4).to_d)
        next if amount <= 0

        credited = state.calendar.trading_day_on_or_after(quarter_end) || quarter_end
        record_cash(state, credited, "interest", amount, "Quarterly interest on cash balance.")
      end
    end

    def record_cash(state, on, kind, amount, notes)
      state.portfolio.cash_transactions.create!(kind: kind, amount: amount, occurred_on: on, notes: notes)
      state.cash += amount
    end

    # --- trades --------------------------------------------------------------

    # Buys the BUYS_PER_CONTRIBUTION names furthest below their target weight,
    # splitting the investable cash between them in proportion to how far below
    # they are. That is what makes the allocation donut and the sector treemap
    # land near the intended shape without any position being hand-placed, and
    # it is also roughly how a real contribution gets allocated.
    def invest(state, on)
      budget = round_money(state.cash * INVEST_RATIO.to_d)
      return if budget <= 0

      deficits = deficits_for(state, on, budget)
      return if deficits.empty?

      total = deficits.sum { |d| d[:deficit] }
      return if total <= 0

      deficits.each do |entry|
        share_price = entry[:price]
        allocation = budget * entry[:deficit] / total
        shares = (allocation / share_price).floor
        # Fall back to a single share when the split allocation cannot afford
        # one but the whole balance can — otherwise a month with an expensive
        # top pick would buy nothing at all and just accumulate cash.
        shares = 1 if shares.zero? && share_price <= state.cash
        next if shares < 1

        cost = round_money(shares * share_price)
        next if cost > state.cash

        buy(state, on, entry[:instrument], shares, share_price, "Monthly contribution buy.")
      end
    end

    def deficits_for(state, on, budget)
      values = state.plan.targets.keys.to_h do |symbol|
        instrument = state.instruments.fetch(symbol)
        [ symbol, state.shares.fetch(symbol, 0.to_d) * price_on(instrument, on) ]
      end
      total = values.values.sum + budget

      state.plan.targets.filter_map { |symbol, weight|
        deficit = (total * weight.to_d) - values.fetch(symbol)
        next if deficit <= 0
        { symbol: symbol, deficit: deficit, instrument: state.instruments.fetch(symbol),
          price: price_on(state.instruments.fetch(symbol), on) }
      }.max_by(BUYS_PER_CONTRIBUTION) { |entry| entry[:deficit] }
    end

    def buy(state, on, instrument, shares, price, notes)
      state.portfolio.transactions.create!(
        instrument: instrument, side: "buy", kind: "normal", shares: shares,
        price: price, fees: 0, executed_on: on, notes: notes
      )
      cost = round_money(shares * price)
      state.shares[instrument.symbol] = state.shares.fetch(instrument.symbol, 0.to_d) + shares
      state.cash -= cost
      state.invested += cost
    end

    def sell(state, on, symbol, fraction, notes)
      instrument = state.instruments.fetch(symbol)
      held = state.shares.fetch(symbol, 0.to_d)
      shares = (held * fraction.to_d).floor
      return if shares < 1

      price = price_on(instrument, on)
      state.portfolio.transactions.create!(
        instrument: instrument, side: "sell", kind: "normal", shares: shares,
        price: price, fees: 0, executed_on: on, notes: notes
      )
      state.shares[symbol] = held - shares
      state.cash += round_money(shares * price)
    end

    # Splits are applied to the seeder's OWN share tracking only — the app
    # derives positions from `split_events` itself, so writing adjusted share
    # counts into the ledger would double-apply the factor.
    def apply_splits(state, instrument, from, on)
      splits(instrument).each do |ex_date, ratio|
        next unless in_window?(ex_date, from, on)
        held = state.shares.fetch(instrument.symbol, 0.to_d)
        next if held.zero?
        state.shares[instrument.symbol] = (held * ratio).floor
      end
    end

    # --- recurring rules -----------------------------------------------------

    # These exist so the recurring-transactions page has something real to show.
    # `next_run_on` is placed in the FUTURE deliberately: the model clamps a past
    # date forward, but an anchor in the past would still let the nightly
    # materializer decide the rule is overdue and write trades that were never
    # part of the plan, which would move every figure in the screenshots.
    def create_recurring(state)
      state.plan.recurring.each do |rule|
        instrument = state.instruments[rule[:symbol]] or next
        anchor = next_month_day(rule[:day])
        state.portfolio.recurring_transactions.create!(
          instrument: instrument, side: "buy", amount_type: "dollars",
          dollar_amount: rule[:dollars], frequency: rule[:frequency],
          anchor_on: anchor, next_run_on: anchor, active: true
        )
      end
    end

    def next_month_day(day)
      candidate = today.change(day: [ day, today.end_of_month.day ].min)
      candidate > today ? candidate : (today >> 1).change(day: day)
    end

    # --- data access ---------------------------------------------------------

    def instruments_for(plan)
      plan.targets.keys.to_h do |symbol|
        instrument = Instrument.find_by("upper(symbol) = ?", symbol.upcase)
        raise "demo:seed needs instrument #{symbol}; run demo:instruments first" if instrument.nil?
        if instrument.daily_prices.where(date: plan.first_month..).count < 100
          raise "demo:seed needs backfilled prices for #{symbol} from #{plan.first_month} " \
                "(have #{instrument.daily_prices.count} bars total)"
        end
        [ symbol, instrument ]
      end
    end

    def calendar_for(plan)
      instrument = Instrument.find_by("upper(symbol) = ?", plan.calendar.upcase)
      raise "demo:seed needs calendar instrument #{plan.calendar}" if instrument.nil?
      TradingDays.new(instrument.daily_prices.order(:date).pluck(:date))
    end

    def benchmark_for(plan)
      return nil if plan.benchmark.nil?
      ::Benchmark.joins(:instrument).find_by("upper(instruments.symbol) = ?", plan.benchmark) ||
        raise("demo:seed needs the #{plan.benchmark} benchmark seeded (bin/rails db:seed)")
    end

    def price_on(instrument, on)
      @prices ||= {}
      @prices[[ instrument.id, on ]] ||=
        instrument.daily_prices.where(date: ..on).order(date: :desc).pick(:close) ||
        raise("no price for #{instrument.symbol} on or before #{on}")
    end

    def dividends(instrument)
      @dividends ||= {}
      @dividends[instrument.id] ||=
        instrument.dividend_events.order(:ex_date).pluck(:ex_date, :cash_per_share)
    end

    def splits(instrument)
      @splits ||= {}
      @splits[instrument.id] ||= instrument.split_events.order(:ex_date).pluck(:ex_date, :ratio)
    end

    def last_priced_day(state)
      state.calendar.days.last
    end

    # --- helpers -------------------------------------------------------------

    # Half-open (from, on]: `from` was already processed by the previous step,
    # so including it would credit the same dividend twice.
    def in_window?(date, from, on)
      return date <= on if from.nil?
      date > from && date <= on
    end

    def quarters_between(from, on)
      quarter = from.end_of_quarter
      [].tap do |ends|
        while quarter < on
          ends << quarter
          quarter = (quarter + 1).end_of_quarter
        end
      end
    end

    def round_money(amount) = amount.to_d.round(2)
    def money(amount) = format("$%.2f", amount)
    def say(message) = io.puts(message)

    # Per-portfolio running state: the position, the cash balance and how far
    # the timeline has been walked. Kept in one object so the step methods can
    # stay small and the invariants (cash mirrors the ledger, shares mirror the
    # trades plus splits) are visible in one place.
    class State
      attr_reader :plan, :instruments, :calendar, :shares
      attr_accessor :portfolio, :cash, :cursor, :invested

      def initialize(plan:, instruments:, calendar:)
        @plan = plan
        @instruments = instruments
        @calendar = calendar
        @shares = {}
        @cash = 0.to_d
        @invested = 0.to_d
        @cursor = nil
      end
    end

    # The traded-day calendar, taken from a reference instrument's own bars
    # rather than from Trading::Calendar: the CAD plan trades on the TSX, whose
    # holidays differ from the NYSE's, and a trade dated on a day the venue was
    # closed would have no bar to be priced from.
    class TradingDays
      attr_reader :days

      def initialize(days)
        @days = days
        @set = days.to_set
      end

      def trading_day_on_or_after(date)
        return date if @set.include?(date)
        days.bsearch { |day| day >= date }
      end
    end
  end
end
