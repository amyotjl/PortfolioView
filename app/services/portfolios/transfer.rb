module Portfolios
  # Portfolio export/import (backlog #064). Two file formats share one pipeline:
  #
  #   file bytes -> Detector -> a Parser -> Document (this file's IR) -> Import
  #
  # The Document is deliberately format-independent and *symbolic*: it names
  # instruments by SYMBOL and benchmarks by NAME, never by primary key, because
  # the whole point of the feature is moving data between databases where ids
  # don't agree (issue #64: "move between environments or make things easier
  # when rebuilding the database").
  #
  # Every money/share field in the IR is a BigDecimal (MoneyMath rejects Floats)
  # and every date is a Date; the parsers own all string coercion so Import
  # never has to guess what it was handed.
  module Transfer
    # Native round-trip format. `FORMAT` is written into the envelope and
    # checked on import — a file whose format string we don't recognize is
    # rejected with a field error rather than half-parsed.
    NATIVE_FORMAT = "portfolioview.portfolios".freeze
    # Bump only for a BREAKING envelope change. Import accepts any version it
    # explicitly knows how to read (SUPPORTED_VERSIONS), so adding an optional
    # key does NOT need a bump.
    NATIVE_VERSION = 1
    SUPPORTED_VERSIONS = [ 1 ].freeze

    # Broker holdings snapshot (the user-supplied Wealthsimple report shape).
    HOLDINGS_CSV_FORMAT = "wealthsimple.holdings".freeze

    # Guard against a hostile/mistaken upload: parsing happens fully in memory,
    # so the byte cap is the real defense. 8 MiB holds ~40k transactions of
    # native JSON — far past any realistic personal portfolio.
    MAX_FILE_BYTES = 8 * 1024 * 1024

    # Raised by the parsers for a file we cannot read at all (bad JSON, no
    # recognizable header, wrong format string). The controller turns it into
    # the 422 envelope keyed on the `file` field — never a 500.
    class UnreadableFile < StandardError; end

    # --- Intermediate representation ------------------------------------------
    #
    # Named *Spec (not Instrument/Portfolio/Transaction) on purpose: bare names
    # would shadow the ActiveRecord models inside this namespace, and Import
    # touches both in the same method bodies.

    # An instrument's full identity, carried in the file itself. This is what
    # lets a non-US listing survive a round trip (and lets the broker CSV
    # introduce one at all): the local `listed_instruments` directory is
    # US/USD-only, so a symbol like ZEQT.TO can never be resolved from it.
    InstrumentSpec = Data.define(:symbol, :name, :instrument_type, :currency, :sector, :industry) do
      def self.build(symbol:, name: nil, instrument_type: "stock", currency: "USD",
                     sector: nil, industry: nil)
        new(symbol: symbol.to_s.strip.upcase, name: name.presence,
            instrument_type: instrument_type, currency: currency,
            sector: sector.presence, industry: industry.presence)
      end
    end

    # `recurring_key` / `scheduled_for` round-trip the materialization
    # idempotency link (transactions.recurring_transaction_id + the partial
    # unique index on [recurring_transaction_id, scheduled_for]). Dropping them
    # would let the nightly materializer re-create slots the file already
    # contains, silently double-counting a month of contributions.
    TransactionSpec = Data.define(
      :symbol, :side, :kind, :shares, :price, :fees, :executed_on, :notes,
      :recurring_key, :scheduled_for
    )

    # `key` is file-local (e.g. "r1") and exists only so TransactionSpec can
    # point at a rule that has no id yet.
    RecurringSpec = Data.define(
      :key, :symbol, :side, :amount_type, :dollar_amount, :share_amount,
      :frequency, :anchor_on, :next_run_on, :end_on, :active
    )

    # `warnings` are per-portfolio, non-fatal notes (a dropped short position, a
    # benchmark that doesn't exist here). They are surfaced to the user rather
    # than swallowed — a silent partial import is the failure mode this feature
    # can least afford.
    PortfolioSpec = Data.define(:name, :benchmark_name, :transactions, :recurring_transactions, :warnings)

    Document = Data.define(:format, :instruments, :portfolios, :warnings) do
      # symbol (upcased) => InstrumentSpec
      def instrument_index
        instruments.index_by { |spec| spec.symbol.upcase }
      end
    end
  end
end
