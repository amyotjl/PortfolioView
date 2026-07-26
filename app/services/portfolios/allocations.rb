module Portfolios
  # As-of-latest allocation breakdown for the two donut charts (docs/PLAN.md
  # § API contract / § Frontend): by_instrument and by_sector, each slice a
  # value and a weight (fraction of total). ETFs/funds with no sector metadata
  # collapse into the single "ETF / Fund" bucket (Instrument#sector_label).
  #
  # Valued at the last trading day using each held instrument's most recent
  # close on or before it. All arithmetic is BigDecimal; weights are value/total
  # so they sum to 1 within rounding. An empty (or wholly unpriced) portfolio
  # yields a well-formed zero payload, never an error.
  class Allocations
    # `sector` on an instrument slice is the SAME label the instrument contributes
    # to by_sector (Instrument#sector_label, "ETF / Fund" when unset). It is what
    # makes the sector -> instrument hierarchy derivable client-side for the
    # treemap (backlog #049 / #53): by_instrument and by_sector are otherwise two
    # flat lists with no join key, and `instruments` is not reachable from the
    # frontend by id (see frontend lib/instrumentIds.ts on why search has no id).
    InstrumentSlice = Data.define(:instrument_id, :symbol, :sector, :value, :weight)
    SectorSlice     = Data.define(:sector, :value, :weight)
    Result          = Data.define(:as_of, :total_value, :by_instrument, :by_sector)

    def self.call(...) = new(...).call

    def initialize(portfolio:)
      @portfolio = portfolio
    end

    def call
      as_of = Trading::Calendar.last_day
      return empty if as_of.nil?

      holdings = Holdings::Calculator.call(portfolio: portfolio, from: as_of, to: as_of).holdings[as_of] || {}
      return empty if holdings.empty?

      instruments = Instrument.where(id: holdings.keys).index_by(&:id)
      closes      = latest_closes(holdings.keys, as_of)

      valued = holdings.filter_map do |iid, shares|
        close = closes[iid]
        close ? [ iid, shares * close ] : nil # an unpriced holding contributes nothing
      end

      total = valued.sum(BigDecimal(0)) { |_iid, value| value }
      return empty if total <= 0

      Result.new(
        as_of: as_of,
        total_value: total,
        by_instrument: instrument_slices(valued, instruments, total).freeze,
        by_sector: sector_slices(valued, instruments, total).freeze
      )
    end

    private

    attr_reader :portfolio

    def instrument_slices(valued, instruments, total)
      valued.map do |iid, value|
        InstrumentSlice.new(
          instrument_id: iid,
          symbol: instruments[iid]&.symbol,
          sector: instruments[iid]&.sector_label || Instrument::SECTOR_FALLBACK,
          value: value,
          weight: (value / total).round(8)
        )
      end.sort_by { |s| -s.value }
    end

    def sector_slices(valued, instruments, total)
      valued.group_by { |iid, _v| instruments[iid]&.sector_label || Instrument::SECTOR_FALLBACK }
            .map do |sector, group|
        value = group.sum(BigDecimal(0)) { |_iid, v| v }
        SectorSlice.new(sector: sector, value: value, weight: (value / total).round(8))
      end.sort_by { |s| -s.value }
    end

    # Most recent close on/before as_of per instrument (one query, DISTINCT ON).
    def latest_closes(instrument_ids, as_of)
      DailyPrice.where(instrument_id: instrument_ids, date: ..as_of)
                .select("DISTINCT ON (instrument_id) instrument_id, close")
                .order(:instrument_id, date: :desc)
                .map { |row| [ row.instrument_id, row.close ] }
                .to_h
    end

    def empty
      Result.new(as_of: nil, total_value: BigDecimal(0), by_instrument: [].freeze, by_sector: [].freeze)
    end
  end
end
