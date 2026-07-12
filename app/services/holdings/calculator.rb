module Holdings
  # Split-correct share-count sweep — the correctness crux (docs/PLAN.md
  # § Core domain logic).
  #
  # Transactions are stored exactly as executed (trade-date share basis),
  # prices unadjusted, splits as events; share counts roll FORWARD at read
  # time via the cumulative split factor:
  #
  #   CSF(i, t, D) = ∏ ratio of splits with  t < ex_date ≤ D
  #   shares(i, D) = Σ  sign(side) × tx.shares × CSF(i, tx.executed_on, D)
  #
  # A split applies at the START of its ex-date, before same-day
  # transactions — so a transaction ON the ex-date is already in the
  # post-split basis (its CSF excludes that day's split).
  #
  # Implemented as one chronological sweep carrying a running position per
  # instrument (mathematically identical to per-transaction CSF products):
  # per date, split ratios multiply the running position first, then the
  # date's transaction deltas apply, then the position is snapshotted if the
  # date is a trading day. Transactions dated on non-trading days (weekends)
  # therefore surface in the next trading day's snapshot.
  #
  # Exactly 3 queries per call: transactions, splits, trading days — no N+1.
  # Passing `transactions:` (any objects responding to instrument_id / side /
  # shares / executed_on, e.g. Benchmarks::Simulation's synthetic trades)
  # replaces the transactions query and drops the count to 2.
  class Calculator
    # Positions whose absolute share count falls to zero (within tolerance)
    # are dropped from the snapshot rather than lingering as 0-share keys.
    ZERO_TOLERANCE = BigDecimal("1e-9")

    # holdings: { Date => { instrument_id => BigDecimal shares } }, one key per
    # trading day in from..to (ascending), deep-frozen.
    Result = Data.define(:holdings)

    Event = Data.define(:date, :instrument_id, :delta)
    private_constant :Event

    def self.call(...) = new(...).call

    def initialize(portfolio:, from:, to:, transactions: nil)
      @portfolio = portfolio
      @from = from
      @to = to
      @transactions = transactions
    end

    def call
      events = transaction_events                                # query 1 (unless injected)
      splits = split_events(events.map(&:instrument_id).uniq)    # query 2
      days   = Trading::Calendar.days_between(from, to)          # query 3

      Result.new(holdings: sweep(events, splits, days))
    end

    private

    attr_reader :portfolio, :from, :to, :transactions

    def transaction_events
      rows =
        if transactions
          transactions.select { |tx| tx.executed_on <= to }
                      .map { |tx| [ tx.instrument_id, tx.side, tx.shares, tx.executed_on ] }
        else
          Transaction.where(portfolio_id: portfolio.id)
                     .where(executed_on: ..to)
                     .pluck(:instrument_id, :side, :shares, :executed_on)
        end

      rows.map do |instrument_id, side, shares, executed_on|
        sign = side == "sell" ? -1 : 1
        Event.new(date: executed_on, instrument_id: instrument_id,
                  delta: MoneyMath.decimal(shares) * sign)
      end
    end

    def split_events(instrument_ids)
      SplitEvent.where(instrument_id: instrument_ids)
                .where(ex_date: ..to)
                .pluck(:instrument_id, :ex_date, :ratio)
    end

    def sweep(events, splits, days)
      events_by_date = events.group_by(&:date)
      splits_by_date = splits.group_by { |_iid, ex_date, _ratio| ex_date }
      snapshot_days  = days.to_set

      position  = Hash.new(BigDecimal(0))
      snapshots = {}

      all_dates = (events_by_date.keys | splits_by_date.keys | days).sort
      all_dates.each do |date|
        # Splits first: they apply at the START of their ex-date, before any
        # same-day transaction.
        splits_by_date[date]&.each do |instrument_id, _ex_date, ratio|
          position[instrument_id] *= ratio if position.key?(instrument_id)
        end
        events_by_date[date]&.each do |event|
          position[event.instrument_id] += event.delta
        end
        snapshots[date] = snapshot(position) if snapshot_days.include?(date)
      end

      snapshots.freeze
    end

    def snapshot(position)
      position.reject { |_id, shares| shares.abs <= ZERO_TOLERANCE }.freeze
    end
  end
end
