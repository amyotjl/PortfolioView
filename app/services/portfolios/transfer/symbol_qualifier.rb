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

      # Fallback venue for a file that identifies a security as non-US but names
      # no venue — the Wealthsimple ACTIVITY export (#068) has no MIC/Exchange
      # column at all. `.TO` because the TSX is far and away the most common
      # Canadian venue; a wrong-but-consistent suffix still achieves the only
      # thing the suffix is for, which is not colliding with a US ticker.
      # InstrumentResolver's sibling lookup is what keeps this in step with a
      # `.NE` symbol the holdings report may already have created.
      DEFAULT_NON_US_SUFFIX = ".TO".freeze

      # Returns the qualified symbol, uppercased. Never returns blank for a
      # non-blank input.
      #
      # assume_non_us: the CALLER has established, by some means other than a
      # venue column, that this security is not US-listed (the activities parser
      # reads it off an "FX Rate:" marker in the row description). Only consulted
      # when no MIC/exchange is supplied.
      def self.call(symbol:, mic: nil, exchange: nil, currency: nil, assume_non_us: false)
        new(symbol: symbol, mic: mic, exchange: exchange, currency: currency,
            assume_non_us: assume_non_us).call
      end

      def initialize(symbol:, mic: nil, exchange: nil, currency: nil, assume_non_us: false)
        @symbol = symbol.to_s.strip.upcase
        @mic = mic.to_s.strip.upcase
        @exchange = exchange.to_s.strip.upcase
        @currency = currency.to_s.strip.upcase
        @assume_non_us = assume_non_us
      end

      def call
        return @symbol if @symbol.blank?
        # Already venue-qualified by the broker (the report contains "XNDU.TO"),
        # so suffixing again would produce XNDU.TO.TO.
        return @symbol if already_qualified?
        return @symbol if us_venue?

        suffix = suffix_for_venue || (@assume_non_us ? DEFAULT_NON_US_SUFFIX : nil)
        return @symbol if suffix.nil?

        "#{@symbol}#{suffix}"
      end

      private

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
