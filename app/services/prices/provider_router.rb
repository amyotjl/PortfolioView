module Prices
  # Decides WHICH price provider serves a given instrument (issue #66).
  #
  # Until now there was nothing to decide: every instrument was US-listed and
  # Tiingo served all of them. Canadian support breaks that, because Tiingo's
  # published directory contains zero Canadian rows — so the choice is not a
  # preference or a failover, it is the difference between having prices and
  # having none.
  #
  # THE SIGNAL IS THE VENUE SUFFIX, and deliberately not a new one. #64 already
  # established that a non-US listing carries a Yahoo-style suffix
  # (`ZEQT.TO`, `FINN.NE`) precisely so it can never alias the US ticker of the
  # same name, and Portfolios::Transfer::SymbolQualifier is the single place
  # that mints them. Reusing KNOWN_SUFFIXES means "what counts as non-US" has
  # exactly one definition; inventing a second test here is how the importer
  # and the price pipeline would quietly disagree about `META` vs `META.TO`.
  #
  # A bare symbol therefore stays on Tiingo, unchanged, including its failover
  # and its budget. Nothing about the US path moves.
  class ProviderRouter
    # `budget_name` is nil for a KEYLESS provider. Yahoo has no account, no
    # quota and nothing to charge — but callers must not read that as "free to
    # hammer": there is no published rate limit either, and Yahoo blocks
    # aggressive callers, so the per-instrument request shape stays the same.
    # Holds the provider CLASS, not an instance, and builds on demand. Asking
    # "who serves this symbol?" must not construct anything: a keyed adapter
    # raises ConfigurationError from its constructor when its key is unset, so
    # an eager build would make that error pre-empt the budget check the caller
    # does first — reordering which failure wins and turning a reschedulable
    # BudgetExceeded into a terminal ConfigurationError. The existing
    # FetchInstrumentJob suite caught exactly that.
    Route = Data.define(:provider_class, :name, :budget_name) do
      def provider = provider_class.new

      def budgeted? = !budget_name.nil?

      # TwelveData is a forward-delta fallback for Tiingo only. It cannot serve
      # a Canadian symbol (its free tier 403s them) and it never returns
      # events, so failing over on the Yahoo path would silently substitute a
      # different price basis for the one source that has the data.
      def failover? = name == TIINGO
    end

    TIINGO = "tiingo".freeze
    YAHOO = "yahoo".freeze

    class << self
      def for(instrument) = call(symbol: instrument.symbol)

      def call(symbol:)
        if non_us?(symbol)
          Route.new(provider_class: PriceProvider::Yahoo, name: YAHOO, budget_name: nil)
        else
          Route.new(provider_class: PriceProvider::Tiingo, name: TIINGO, budget_name: TIINGO)
        end
      end

      # True when the symbol carries one of SymbolQualifier's venue suffixes.
      # Matched against the END of the symbol, so a US ticker that merely
      # contains the letters (there is no `.TO` inside a bare US symbol, but
      # share-class dots like `HPS.A` exist) is unaffected.
      def non_us?(symbol)
        sym = symbol.to_s.strip.upcase
        Portfolios::Transfer::SymbolQualifier::KNOWN_SUFFIXES.any? { |s| sym.end_with?(s) }
      end
    end
  end
end
