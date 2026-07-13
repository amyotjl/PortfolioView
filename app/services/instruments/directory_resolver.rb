module Instruments
  # Resolves a user-supplied ticker SYMBOL into a tradeable Instrument row
  # (docs/PLAN.md § API contract: "POST by symbol, validated vs directory,
  # USD/US-exchange only in v1").
  #
  # An already-known instrument short-circuits: it was validated the first time
  # it was referenced, and re-checking it against a since-refreshed directory
  # could wrongly reject a symbol the user already holds. A brand-new symbol is
  # validated against the local listed_instruments directory (no provider HTTP —
  # the directory import backs this) and must have at least one USD / US-exchange
  # listing before an Instrument is find-or-created. Creating the Instrument fires
  # its after_create_commit backfill + metadata jobs (Instrument model).
  #
  # Returns a frozen Result: on success #instrument is set and #error is nil; on
  # failure #instrument is nil and #error is a single field message the controller
  # maps onto the `symbol` form field in the 422 envelope.
  class DirectoryResolver
    # Tiingo's supported_tickers exchange codes considered US venues for v1.
    # Non-US listings (e.g. LSE, TSX) and non-USD rows are out of scope until
    # multi-currency support lands (docs/PLAN.md § Deferred to v1.1+).
    US_EXCHANGES = [
      "NYSE", "NASDAQ", "AMEX", "NYSE ARCA", "NYSE MKT", "BATS", "IEX", "CBOE"
    ].to_set.freeze

    Result = Data.define(:instrument, :error) do
      def ok? = error.nil?
    end

    def self.call(...) = new(...).call

    def initialize(symbol:)
      @raw_symbol = symbol
    end

    def call
      symbol = @raw_symbol.to_s.strip.upcase
      return failure("is required") if symbol.blank?

      existing = Instrument.where("upper(symbol) = ?", symbol).first
      return Result.new(instrument: existing, error: nil) if existing

      listing = usd_us_listing_for(symbol)
      return failure("is not a recognized US-exchange symbol (unsupported in v1)") if listing.nil?

      instrument = Instrument.create!(
        symbol: symbol,
        name: listing.name,
        instrument_type: instrument_type_for(listing),
        currency: "USD"
      )
      Result.new(instrument: instrument, error: nil)
    end

    private

    # A symbol can be listed on several venues; accept it if ANY listing is a
    # USD row on a recognized US exchange, and build the Instrument from it.
    def usd_us_listing_for(symbol)
      ListedInstrument.where("upper(symbol) = ?", symbol).find do |li|
        li.currency.to_s.upcase == "USD" && US_EXCHANGES.include?(li.exchange.to_s.strip.upcase)
      end
    end

    def instrument_type_for(listing)
      listing.asset_type.to_s.downcase.include?("etf") ? "etf" : "stock"
    end

    def failure(message)
      Result.new(instrument: nil, error: message)
    end
  end
end
