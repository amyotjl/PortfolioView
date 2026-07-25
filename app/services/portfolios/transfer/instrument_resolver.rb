module Portfolios
  module Transfer
    # Resolves a Document's symbols to Instrument rows during an import.
    #
    # HOW THIS DIFFERS FROM Instruments::DirectoryResolver — and why both exist.
    #
    # DirectoryResolver serves the transaction FORM, where the only thing known
    # about a symbol is the string the user typed; it must therefore validate
    # against the local `listed_instruments` directory, which Tiingo publishes and
    # which is US/USD-only (verified: 0 of 106,253 rows are CAD or on a Canadian
    # venue). That is the right rule for typed input and is left untouched.
    #
    # An import file is a different kind of input: it CARRIES the instrument's
    # identity (name, type, currency) alongside the symbol. So this resolver
    # trusts the file for instruments the directory cannot know about, which is
    # what lets a non-US listing round-trip and what lets a broker CSV introduce
    # one at all. Symbols the file doesn't describe still fall through to
    # DirectoryResolver, so a minimal hand-written file listing only US tickers
    # works with no `instruments` section.
    #
    # An instrument that already exists is REUSED AS-IS and never rewritten from
    # the file: the local row may have richer, fresher provider metadata (sector
    # and industry arrive from FMP), and an import must not be able to downgrade
    # it or repoint a symbol at a different security.
    class InstrumentResolver
      Result = Data.define(:instrument, :error) do
        def ok? = error.nil?
      end

      def initialize(instrument_specs)
        @specs = instrument_specs.index_by { |spec| spec.symbol.upcase }
        @cache = {}
        # Whether the directory has been imported at all. If it is empty we can
        # draw NO conclusion about provider coverage — see #provider_eligible?.
        @directory_populated = ListedInstrument.exists?
      end

      def resolve(symbol)
        key = symbol.to_s.strip.upcase
        return Result.new(instrument: nil, error: "is required") if key.blank?

        @cache[key] ||= resolve_uncached(key)
      end

      private

      def resolve_uncached(key)
        existing = Instrument.find_by("upper(symbol) = ?", key)
        return Result.new(instrument: existing, error: nil) if existing

        spec = @specs[key]
        # No identity in the file: fall back to typed-input rules so we never
        # invent an instrument out of a bare, unvouched-for ticker.
        return directory_fallback(key) if spec.nil?

        Result.new(instrument: create_from(spec), error: nil)
      end

      def directory_fallback(key)
        result = Instruments::DirectoryResolver.call(symbol: key)
        return Result.new(instrument: result.instrument, error: nil) if result.ok?

        Result.new(
          instrument: nil,
          error: "#{result.error} — and the import file carries no instrument details for it"
        )
      end

      def create_from(spec)
        instrument = Instrument.new(
          symbol: spec.symbol,
          name: spec.name,
          instrument_type: spec.instrument_type,
          currency: spec.currency,
          sector: spec.sector,
          industry: spec.industry
        )
        instrument.skip_provider_jobs = !provider_eligible?(spec.symbol)
        instrument.save!
        instrument
      end

      # Should creating this instrument trigger the first-reference Tiingo
      # backfill + FMP metadata jobs?
      #
      # The test is "does the provider's own published directory list this
      # symbol". Firing a backfill for a symbol Tiingo demonstrably doesn't serve
      # spends a slot of the scarce MONTHLY UNIQUE-SYMBOL quota
      # (PriceProvider::Budget#register_symbol!) to learn nothing — and a 14-row
      # holdings import would spend fourteen.
      #
      # The empty-directory case must stay permissive: on a freshly rebuilt
      # database (the headline use case for this feature) Directory::ImportJob may
      # not have run yet, and suppressing there would leave every imported
      # instrument permanently un-backfilled.
      def provider_eligible?(symbol)
        return true unless @directory_populated

        ListedInstrument.exists?([ "upper(symbol) = ?", symbol.upcase ])
      end
    end
  end
end
