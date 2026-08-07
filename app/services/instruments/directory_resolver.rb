module Instruments
  # Resolves a user-supplied ticker SYMBOL into a tradeable Instrument row
  # (docs/PLAN.md § API contract: "POST by symbol, validated vs directory").
  # US listings and, since issue #66, Canadian ones — the latter identified by
  # their venue suffix (ZEQT.TO), which is how the directory stores them and how
  # they stay distinct from the US ticker of the same name.
  #
  # An already-known instrument short-circuits: it was validated the first time
  # it was referenced, and re-checking it against a since-refreshed directory
  # could wrongly reject a symbol the user already holds. A brand-new symbol is
  # validated against the local listed_instruments directory (no provider HTTP —
  # the directory imports back this) and must have at least one TRADEABLE
  # listing before an Instrument is find-or-created: USD on a US exchange, or
  # CAD on a Canadian one (ListedInstrument::TRADEABLE_SQL owns that test). Creating the Instrument fires
  # its after_create_commit backfill + metadata jobs (Instrument model).
  #
  # Returns a frozen Result: on success #instrument is set and #error is nil; on
  # failure #instrument is nil and #error is a single field message the controller
  # maps onto the `symbol` form field in the 422 envelope.
  class DirectoryResolver
    # Tiingo's supported_tickers exchange codes considered US venues for v1.
    # Non-US listings (e.g. LSE, TSX) and non-USD rows are out of scope until
    # multi-currency support lands (docs/PLAN.md § Deferred to v1.1+).
    #
    # Defined on ListedInstrument (a property of directory rows) and aliased
    # here because this name is the one referenced elsewhere — notably
    # Portfolios::Transfer::SymbolQualifier. One list, two readers: what may
    # become an Instrument, and what #search ranks first (issue #63).
    US_EXCHANGES = ListedInstrument::US_EXCHANGES

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

      listing = tradeable_listing_for(symbol)
      return failure(unresolvable_message) if listing.nil?

      instrument = Instrument.create!(
        symbol: symbol,
        name: listing.name,
        instrument_type: instrument_type_for(listing),
        # From the LISTING, not hardcoded USD (issue #66). A Canadian row is
        # CAD, and stamping it USD would make Prices::ProviderRouter's feed and
        # the instrument's own currency disagree about what it is.
        currency: listing.currency.to_s.strip.upcase.presence || "USD"
      )
      Result.new(instrument: instrument, error: nil)
    end

    private

    # A symbol can be listed on several venues; accept it if ANY listing is
    # tradeable here — a USD row on a US exchange, or (since #66) a CAD row on a
    # Canadian one — and build the Instrument from it.
    #
    # Delegates the predicate to ListedInstrument.tradeable rather than
    # re-stating it in Ruby (issue #71) — the same test also drives search
    # ranking, and two copies could drift apart silently. Ordered so the chosen
    # listing is deterministic: the previous `.find` walked rows in whatever
    # order Postgres returned them, so which venue named the Instrument was
    # unspecified whenever a symbol had more than one qualifying listing.
    #
    # Note the SYMBOL carries the venue for Canadian rows (`ZEQT.TO`), because
    # Directory::ImportCanadianJob stores them suffixed — so this lookup is
    # already unambiguous and cannot match the US ticker of the same name.
    def tradeable_listing_for(symbol)
      ListedInstrument.where("upper(symbol) = ?", symbol).tradeable.order(:id).first
    end

    # An EMPTY directory and an unknown symbol are different failures and must
    # not share a message (issue #72). A fresh deploy has no directory until the
    # import runs, so every symbol fails this check — and telling the user their
    # ticker "is not recognized" blames their input for a cache that was never
    # provisioned. They then retype a symbol that was always correct.
    #
    # Checked only on the failure path, so the happy path costs nothing.
    def unresolvable_message
      if ListedInstrument.none?
        "can't be checked yet — the symbol directory is still downloading. " \
          "This is a one-time setup step; try again in a few minutes."
      else
        # Wording covers both supported markets since #66. A Canadian listing
        # must be typed with its venue suffix (ZEQT.TO, FINN.NE) — that is how
        # the directory stores it, and how it stays distinct from the US ticker
        # of the same name.
        "is not a recognized US or Canadian exchange symbol " \
          "(Canadian listings need their venue suffix, e.g. ZEQT.TO)"
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
