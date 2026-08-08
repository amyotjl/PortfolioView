module Portfolios
  module Transfer
    # Turns a broker row's (symbol, MIC/exchange) pair into a symbol that is
    # unique in the `instruments` table.
    #
    # WHY THIS EXISTS — the collision is real, not theoretical. `instruments` has
    # a UNIQUE index on upper(symbol) alone, so a symbol is the app's whole
    # instrument identity. The user's Wealthsimple report contains:
    #
    #   META  XTSE  CAD  "Meta CDR (CAD Hedged)"      <- a TSX depositary receipt
    #   GOOG  XTSE  CAD  "Alphabet CDR (CAD Hedged)"  <- ditto
    #   FINN  NEOE  CAD  "Fidelity Global Innovators" <- a CBOE Canada ETF
    #
    # Imported unqualified, all three would bind to the *existing* NASDAQ/PINK
    # USD rows of the same ticker: wrong currency, wrong price history, and — for
    # a CDR, which is a hedged fraction of the underlying share — wrong
    # quantities too. That is silent data corruption, so a non-US listing gets an
    # exchange suffix and can never alias a US ticker.
    #
    # The suffixes are the widely used Yahoo/Tiingo-style venue suffixes rather
    # than an invention of ours, so an eventual multi-currency price provider can
    # consume them unchanged.
    class SymbolQualifier
      # MIC (ISO 10383) -> venue suffix. MIC is preferred over the human
      # "Exchange" column because it is unambiguous.
      SUFFIX_BY_MIC = {
        "XTSE" => ".TO",   # Toronto Stock Exchange
        "XTSX" => ".V",    # TSX Venture
        "XCNQ" => ".CN",   # Canadian Securities Exchange
        "NEOE" => ".NE",   # CBOE Canada (formerly NEO)
        "XLON" => ".L",    # London
        "XPAR" => ".PA",   # Euronext Paris
        "XETR" => ".DE",   # Xetra
        "XSWX" => ".SW",   # SIX Swiss
        "XTKS" => ".T",    # Tokyo
        "XASX" => ".AX",   # ASX
        "XHKG" => ".HK"    # Hong Kong
      }.freeze

      # Fallback when a row carries no MIC — matched against the free-text
      # "Exchange" column. Ordered longest-first so "CBOE CANADA" is tested
      # before a bare "CBOE" could ever match it.
      SUFFIX_BY_EXCHANGE = {
        "CBOE CANADA" => ".NE",
        "NEO" => ".NE",
        "TSX VENTURE" => ".V",
        "TSXV" => ".V",
        "TSX" => ".TO",
        "TORONTO" => ".TO",
        "CSE" => ".CN",
        "LSE" => ".L",
        "LONDON" => ".L"
      }.freeze

      # US venues: no suffix, because these are the rows the local
      # `listed_instruments` directory already indexes under the bare ticker.
      US_MICS = %w[XNYS XNAS XNGS XNMS XNCM ARCX BATS BATY IEXG XASE XCBO XCIS].to_set.freeze
      US_EXCHANGES = Instruments::DirectoryResolver::US_EXCHANGES

      KNOWN_SUFFIXES = (SUFFIX_BY_MIC.values | SUFFIX_BY_EXCHANGE.values).to_set.freeze

      # Last-resort venue for a file that identifies a security as non-US but
      # names no venue — the Wealthsimple ACTIVITY export (#068) has no
      # MIC/Exchange column at all.
      #
      # `.TO` WAS ONCE THE ONLY ANSWER AND IS NOW THE FALLBACK OF LAST RESORT
      # (#79). The original reasoning was that the TSX is the most common
      # Canadian venue and that a wrong-but-consistent suffix still achieves the
      # suffix's only job, which is not colliding with a US ticker. #66 made the
      # cost measurable for the first time and it is worse than "most common"
      # suggested: re-measured 2026-08-07, **5,998 of 8,651 CAD listings (69.3%)
      # are not on the TSX** — NEO 3,586, TSX 2,653, TSXV 1,681, CSE 731 — so the
      # guess is wrong for the majority. (#79 quotes 5,995 of 8,627 from an
      # earlier import of the directory; the ratio is the same.) `FINN` is the
      # worked example — this yields `FINN.TO`, which 404s at every price
      # provider, while the real listing is `FINN.NE` on Cboe Canada.
      #
      # #66 also made it FIXABLE for the first time, by importing Canadian rows
      # into `listed_instruments`: before it there was no `FINN.NE` row to look
      # up. So a venue-less symbol is now resolved against the directory first
      # (see DirectoryVenueLookup) and only falls back here when the directory
      # cannot answer.
      #
      # IT IS STILL A FALLBACK AND NOT AN ERROR, deliberately. Rejecting an
      # unresolvable symbol would regress #68's import badly: 7 of the 9 symbols
      # in the user's real Wealthsimple report do not exist in the directory
      # under any spelling, and refusing them would turn a working import into a
      # failing one. What changes is that the guess is no longer SILENT — callers
      # can see it was a guess (Result#suffix_source == :default_guess) and say so
      # in the import report.
      DEFAULT_NON_US_SUFFIX = ".TO".freeze

      # Where the venue suffix came from. Callers use this to distinguish a
      # KNOWN venue from a GUESS; nothing else about the symbol differs.
      #
      #   :none               no suffix applied (blank, US, or already qualified)
      #   :mic / :exchange    the file named the venue
      #   :directory          resolved against listed_instruments (#79)
      #   :default_guess      no venue anywhere — DEFAULT_NON_US_SUFFIX
      Result = Data.define(:symbol, :suffix_source) do
        def guessed? = suffix_source == :default_guess
      end

      # Resolves a bare, venue-less symbol against the local Canadian directory.
      #
      # Injected rather than called inline so SymbolQualifier stays a pure value
      # object for every other path — a parser qualifying a MIC-bearing row still
      # touches no database — and so tests can drive the ambiguous and absent
      # cases without fixtures.
      #
      # Returns the DISTINCT venue suffixes the directory knows for this base
      # symbol. One is an answer; zero means "not listed here"; more than one is
      # genuinely ambiguous (the same base trades on two Canadian venues) and is
      # NOT resolved by picking one — see #suffix_for_venue_less.
      class DirectoryVenueLookup
        def self.call(base) = new(base).call

        def initialize(base) = @base = base.to_s.upcase

        def call
          return [] if @base.blank?

          candidates = ListedInstrument::CANADIAN_SUFFIXES.map { |s| "#{@base}#{s}" }

          ListedInstrument.tradeable
                          .where(currency: "CAD")
                          .where("upper(symbol) IN (?)", candidates)
                          .pluck(:symbol)
                          .filter_map { |sym| suffix_of(sym.upcase) }
                          .uniq
        end

        private

        def suffix_of(symbol)
          ListedInstrument::CANADIAN_SUFFIXES.find { |s| symbol.end_with?(s) }
        end
      end

      # Returns the qualified symbol, uppercased. Never returns blank for a
      # non-blank input.
      #
      # assume_non_us: the CALLER has established, by some means other than a
      # venue column, that this security is not US-listed (the activities parser
      # reads it off an "FX Rate:" marker in the row description). Only consulted
      # when no MIC/exchange is supplied.
      def self.call(symbol:, mic: nil, exchange: nil, currency: nil, assume_non_us: false,
                    venue_lookup: DirectoryVenueLookup)
        resolve(symbol:, mic:, exchange:, currency:, assume_non_us:, venue_lookup:).symbol
      end

      # Same decision as .call, but reports WHERE the suffix came from so a caller
      # can tell a known venue from a guess (#79). Prefer this in an importer that
      # writes a user-facing report.
      def self.resolve(symbol:, mic: nil, exchange: nil, currency: nil, assume_non_us: false,
                       venue_lookup: DirectoryVenueLookup)
        new(symbol: symbol, mic: mic, exchange: exchange, currency: currency,
            assume_non_us: assume_non_us, venue_lookup: venue_lookup).resolve
      end

      def initialize(symbol:, mic: nil, exchange: nil, currency: nil, assume_non_us: false,
                     venue_lookup: DirectoryVenueLookup)
        @symbol = symbol.to_s.strip.upcase
        @mic = mic.to_s.strip.upcase
        @exchange = exchange.to_s.strip.upcase
        @currency = currency.to_s.strip.upcase
        @assume_non_us = assume_non_us
        @venue_lookup = venue_lookup
      end

      def call = resolve.symbol

      def resolve
        return unsuffixed if @symbol.blank?
        # Already venue-qualified by the broker (the report contains "XNDU.TO"),
        # so suffixing again would produce XNDU.TO.TO.
        return unsuffixed if already_qualified?
        return unsuffixed if us_venue?

        if (suffix = suffix_for_venue)
          return Result.new(symbol: "#{@symbol}#{suffix}",
                            suffix_source: SUFFIX_BY_MIC.key?(@mic) ? :mic : :exchange)
        end

        return unsuffixed unless @assume_non_us

        suffix_for_venue_less
      end

      private

      def unsuffixed = Result.new(symbol: @symbol, suffix_source: :none)

      # The venue-less path (#79). The directory is consulted first and is trusted
      # only when it gives EXACTLY ONE answer.
      #
      # Ambiguity is NOT resolved by picking a venue: if the same base symbol
      # trades on two Canadian venues, choosing one would bind the user's holding
      # to the wrong security some of the time, which is the very corruption a
      # venue suffix exists to prevent. Both the ambiguous case and the unknown
      # case fall back to DEFAULT_NON_US_SUFFIX and are reported as a guess, so
      # the user is told rather than misled.
      #
      # MEASURED COVERAGE, on the real 8,651-row CAD directory (2026-08-07):
      #
      #   distinct CAD base symbols          5,496
      #     exactly one venue -> resolved    2,351  (42.8%)
      #     two or more venues -> guessed    3,145
      #   of the resolved ones, the old bare `.TO` default was WRONG for  1,772
      #
      # So this settles a minority of symbols and corrects 1,772 of them. The 69%
      # figure #79 quotes replicates exactly: 5,998 of 8,651 CAD listings
      # (69.3%) are not on the TSX — NEO 3,586, TSX 2,653, TSXV 1,681, CSE 731.
      #
      # A TEMPTING REFINEMENT THAT IS DELIBERATELY NOT TAKEN. Nearly all the
      # ambiguity is a `.NE` row pairing with a primary listing, because Cboe
      # Canada is an ALTERNATIVE TRADING VENUE for securities listed elsewhere
      # rather than a separate listing. Measured by comparing the names the
      # directory holds for each side:
      #
      #   .NE + .TO   2,063 pairs, same security in 93.9%
      #   .NE + .V      801 pairs, same security in 98.9%
      #   .NE + .CN     264 pairs, same security in 99.6%
      #
      # Dropping `.NE` whenever another venue exists would take coverage from
      # 42.8% to 99.7%, leaving only 17 genuinely ambiguous bases. It is still
      # refused, because it TRADES A SAFE FAILURE FOR A DANGEROUS ONE. Today a
      # wrong guess yields a symbol no provider lists, so the holding shows no
      # price history and a market value of zero while its cost basis stays
      # exact — visibly incomplete, never wrong. Resolving to a real-but-wrong
      # venue would instead attach ANOTHER SECURITY'S PRICE HISTORY to the
      # position, which is silent and looks plausible. And the counterexample is
      # real, not hypothetical: base `HPQ` is "HPQ Silicon Inc." on `.NE` and
      # "HP Inc." on `.V` — different companies sharing a base symbol. Take this
      # refinement only with a same-security check strong enough to exclude that,
      # and note that a missing directory name (common) is not evidence of
      # agreement.
      def suffix_for_venue_less
        suffixes = Array(@venue_lookup.call(@symbol))

        if suffixes.one?
          Result.new(symbol: "#{@symbol}#{suffixes.first}", suffix_source: :directory)
        else
          Result.new(symbol: "#{@symbol}#{DEFAULT_NON_US_SUFFIX}", suffix_source: :default_guess)
        end
      end

      def already_qualified?
        KNOWN_SUFFIXES.any? { |suffix| @symbol.end_with?(suffix) }
      end

      # A US venue keeps the bare ticker. USD alone is NOT enough to conclude
      # "US" (a CAD-listed name can be quoted in USD), so the venue must say so.
      def us_venue?
        return true if US_MICS.include?(@mic)
        return true if US_EXCHANGES.include?(@exchange)
        # An explicit caller assertion outranks the currency guess below — the
        # activities export carries the ACCOUNT's currency on every row, so its
        # `currency` says nothing about where the security is listed.
        return false if @assume_non_us

        # No venue information at all: fall back to currency. A USD row with no
        # venue is treated as US so a minimal hand-written file still works.
        @mic.blank? && @exchange.blank? && (@currency.blank? || @currency == "USD")
      end

      def suffix_for_venue
        return SUFFIX_BY_MIC[@mic] if SUFFIX_BY_MIC.key?(@mic)

        # Longest key first so "CBOE CANADA" wins over "CSE"-style substrings.
        SUFFIX_BY_EXCHANGE
          .keys
          .sort_by { |key| -key.length }
          .find { |key| @exchange == key || @exchange.include?(key) }
          &.then { |key| SUFFIX_BY_EXCHANGE[key] }
      end
    end
  end
end
