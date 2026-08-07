require "test_helper"

# backlog #064: venue-suffixing for non-US listings, which is what stops an
# imported TSX row from aliasing the US ticker of the same name.
module Portfolios
  module Transfer
    class SymbolQualifierTest < ActiveSupport::TestCase
      def qualify(**kwargs) = SymbolQualifier.call(**kwargs)

      # --- The collision this class exists to prevent ---

      test "a TSX CDR does not collide with the US ticker of the same name" do
        assert_equal "META.TO", qualify(symbol: "META", mic: "XTSE", exchange: "TSX", currency: "CAD")
        assert_equal "GOOG.TO", qualify(symbol: "GOOG", mic: "XTSE", exchange: "TSX", currency: "CAD")
      end

      test "a CBOE Canada listing is suffixed, not treated as US CBOE" do
        # "CBOE" IS in DirectoryResolver::US_EXCHANGES, so a naive substring test
        # would classify CBOE CANADA as a US venue and let FINN alias the US FINN.
        assert_equal "FINN.NE", qualify(symbol: "FINN", mic: "NEOE", exchange: "CBOE CANADA", currency: "CAD")
      end

      test "MIC wins over an ambiguous free-text exchange" do
        assert_equal "ABC.TO", qualify(symbol: "ABC", mic: "XTSE", exchange: "CBOE CANADA", currency: "CAD")
      end

      # --- US venues keep the bare ticker ---

      test "US venues are not suffixed" do
        assert_equal "AAPL", qualify(symbol: "AAPL", mic: "XNAS", exchange: "NASDAQ", currency: "USD")
        assert_equal "SPY", qualify(symbol: "SPY", mic: "ARCX", exchange: "NYSE ARCA", currency: "USD")
        assert_equal "IBM", qualify(symbol: "IBM", mic: "", exchange: "NYSE", currency: "USD")
      end

      test "a bare USD symbol with no venue information stays bare" do
        # Keeps a minimal hand-written native file working with no venue columns.
        assert_equal "MSFT", qualify(symbol: "MSFT")
        assert_equal "MSFT", qualify(symbol: "MSFT", currency: "USD")
      end

      # --- Idempotency ---

      test "an already-suffixed symbol is not suffixed twice" do
        assert_equal "XNDU.TO", qualify(symbol: "XNDU.TO", mic: "XTSE", exchange: "TSX", currency: "CAD")
        assert_equal "VOD.L", qualify(symbol: "VOD.L", mic: "XLON", exchange: "LSE", currency: "GBP")
      end

      test "qualifying twice is stable" do
        once = qualify(symbol: "ZEQT", mic: "XTSE", exchange: "TSX", currency: "CAD")
        twice = qualify(symbol: once, mic: "XTSE", exchange: "TSX", currency: "CAD")

        assert_equal once, twice
      end

      # --- Normalization and edges ---

      test "symbols are upcased and stripped" do
        assert_equal "ZEQT.TO", qualify(symbol: "  zeqt ", mic: "xtse", exchange: "tsx", currency: "cad")
      end

      test "a blank symbol is returned unchanged rather than becoming a bare suffix" do
        assert_equal "", qualify(symbol: "", mic: "XTSE")
        assert_equal "", qualify(symbol: "   ", mic: "XTSE")
      end

      test "an unrecognized non-US venue falls through unsuffixed rather than guessing" do
        # Better to import the bare symbol than to invent a suffix that no price
        # provider would recognize.
        assert_equal "ABC", qualify(symbol: "ABC", mic: "XXXX", exchange: "SOME EXCHANGE", currency: "EUR")
      end

      test "a CAD row with no venue at all is not assumed to be US" do
        assert_equal "ABC", qualify(symbol: "ABC", currency: "CAD")
      end
      # --- #79: the venue-less path resolves against the directory -------------

      # A stub lookup keeps the ambiguous and unknown cases testable without
      # needing directory rows, and proves the lookup is INJECTED rather than
      # called inline.
      def lookup_returning(*suffixes) = ->(_base) { suffixes }

      test "a venue-less non-US symbol takes the venue the directory knows" do
        result = SymbolQualifier.resolve(symbol: "FINN", assume_non_us: true,
                                        venue_lookup: lookup_returning(".NE"))

        assert_equal "FINN.NE", result.symbol
        assert_equal :directory, result.suffix_source
        assert_not result.guessed?, "a directory hit is not a guess"
      end

      test "resolving against the REAL directory finds the venue, not the TSX" do
        # The worked example from #79. Before this, FINN became FINN.TO, which
        # 404s at every provider, while the real listing is FINN.NE on Cboe
        # Canada. #66 is what made this fixable: before it there was no such row.
        ListedInstrument.create!(symbol: "FINN.NE", exchange: "NEO", asset_type: "ETF",
                                 currency: "CAD")

        assert_equal "FINN.NE", SymbolQualifier.call(symbol: "FINN", assume_non_us: true)
      end

      test "an AMBIGUOUS base symbol is not resolved by picking a venue" do
        # The same base trading on two Canadian venues. Choosing one would bind
        # the holding to the wrong security half the time — the exact corruption
        # a venue suffix exists to prevent — so it falls back and says so.
        result = SymbolQualifier.resolve(symbol: "ACO", assume_non_us: true,
                                        venue_lookup: lookup_returning(".TO", ".NE"))

        assert_equal "ACO.TO", result.symbol
        assert result.guessed?, "two candidate venues is a guess, not an answer"
      end

      test "a symbol the directory does not list falls back to the TSX, as a GUESS" do
        # Load-bearing that this is not an error: 7 of the 9 symbols in the real
        # Wealthsimple report are absent from the directory under any spelling,
        # and rejecting them would turn a working import into a failing one.
        result = SymbolQualifier.resolve(symbol: "NOTLISTED", assume_non_us: true,
                                        venue_lookup: lookup_returning)

        assert_equal "NOTLISTED.TO", result.symbol
        assert_equal :default_guess, result.suffix_source
      end

      test "the directory is NOT consulted when the file names the venue" do
        # SymbolQualifier stays a pure value object on every path but the
        # venue-less one; a MIC-bearing row must not touch the database.
        exploding = ->(_base) { raise "the venue lookup must not be called" }

        assert_equal "FINN.NE", SymbolQualifier.call(symbol: "FINN", mic: "NEOE",
                                                    currency: "CAD", venue_lookup: exploding)
        assert_equal "AAPL", SymbolQualifier.call(symbol: "AAPL", mic: "XNAS",
                                                 currency: "USD", venue_lookup: exploding)
        assert_equal "ZEQT.TO", SymbolQualifier.call(symbol: "ZEQT.TO", assume_non_us: true,
                                                    venue_lookup: exploding)
      end

      test "suffix_source distinguishes every path" do
        assert_equal :none, SymbolQualifier.resolve(symbol: "").suffix_source
        assert_equal :none, SymbolQualifier.resolve(symbol: "AAPL", mic: "XNAS").suffix_source
        assert_equal :none, SymbolQualifier.resolve(symbol: "ZEQT.TO").suffix_source
        assert_equal :mic, SymbolQualifier.resolve(symbol: "META", mic: "XTSE").suffix_source
        assert_equal :exchange,
                     SymbolQualifier.resolve(symbol: "META", exchange: "TSX",
                                             currency: "CAD").suffix_source
      end

      test ".call still returns a bare String, so existing callers are untouched" do
        assert_instance_of String, SymbolQualifier.call(symbol: "META", mic: "XTSE")
      end
    end
  end
end
