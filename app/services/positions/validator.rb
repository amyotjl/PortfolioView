module Positions
  # No-short-positions guard (docs/PLAN.md § Core domain logic): replays the
  # split-adjusted running position of ONE (portfolio, instrument) pair over a
  # proposed final transaction set — from the first transaction through the
  # last event — and reports the first date on which the position would go
  # negative. Runs on every transaction create/update/destroy (wired in the
  # Transaction model), which catches direct oversells AND backdated edits or
  # deletes that retroactively strand a later sell.
  #
  # Replay granularity is EVENT dates, not trading days, so an oversell dated
  # on a weekend is caught too. Within a date the split applies first (a split
  # takes effect at the START of its ex-date, before same-day transactions),
  # then the date's net transaction delta; the end-of-date position must be
  # non-negative. Same-day buy+sell pairs are therefore judged by their net —
  # with EOD granularity intraday ordering is unknowable, so the day's close
  # position is the invariant.
  #
  # All arithmetic is BigDecimal (MoneyMath rejects Floats).
  class Validator
    Entry = Data.define(:executed_on, :side, :shares)

    Result = Data.define(:valid, :first_offending_date) do
      def valid? = valid
    end

    def self.call(...) = new(...).call

    # transactions: the PROPOSED final set for one (portfolio, instrument) —
    # objects responding to executed_on / side / shares.
    # splits: injectable [[ex_date, ratio], ...]; queried when omitted.
    def initialize(instrument_id:, transactions:, splits: nil)
      @instrument_id = instrument_id
      @transactions = transactions
      @splits = splits
    end

    def call
      deltas_by_date = daily_deltas
      splits_by_date = split_ratios.group_by(&:first)

      position = BigDecimal(0)
      (deltas_by_date.keys | splits_by_date.keys).sort.each do |date|
        # Split first: it applies at the start of its ex-date, so a same-day
        # sell may legitimately unload the full post-split share count.
        splits_by_date[date]&.each { |_ex_date, ratio| position *= ratio }
        position += deltas_by_date.fetch(date, BigDecimal(0))

        return Result.new(valid: false, first_offending_date: date) if position.negative?
      end

      Result.new(valid: true, first_offending_date: nil)
    end

    private

    attr_reader :instrument_id, :transactions

    def daily_deltas
      transactions.each_with_object(Hash.new(BigDecimal(0))) do |tx, deltas|
        sign = tx.side == "sell" ? -1 : 1
        deltas[tx.executed_on] += MoneyMath.decimal(tx.shares) * sign
      end
    end

    def split_ratios
      @splits || SplitEvent.where(instrument_id: instrument_id)
                           .order(:ex_date)
                           .pluck(:ex_date, :ratio)
    end
  end
end
