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
    end
  end
end
