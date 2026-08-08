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

    # Envelope versions. 1 is the original; 2 is 1 plus a per-portfolio
    # `cash_transactions` array (issue #80).
    NATIVE_VERSION_BASE = 1
    NATIVE_VERSION_CASH = 2
    SUPPORTED_VERSIONS = [ NATIVE_VERSION_BASE, NATIVE_VERSION_CASH ].freeze

    # THE VERSION AN EXPORT STAMPS DEPENDS ON WHAT IS IN IT, which is why this is
    # a method and not a constant: 2 iff some exported portfolio carries at least
    # one cash row, else 1. Paired with Export OMITTING the `cash_transactions`
    # key entirely for a portfolio that has none. Both halves are load-bearing.
    #
    #   * Omitting the key keeps a no-cash export BYTE-IDENTICAL to a pre-#80
    #     export, which preserves the asserted export -> import -> export fixed
    #     point with no test churn and no silent reformat of every user's file.
    #   * The conditional version makes a cash-BEARING file fail loudly on an old
    #     build instead of silently losing money. An old NativeParser ignores
    #     unknown keys, so it would drop the whole cash section and produce a
    #     portfolio whose net_deposits, benchmark and candles all differ, with no
    #     warning at all.
    #
    # THIS DELIBERATELY DEPARTS from the rule the old NATIVE_VERSION comment
    # stated — "adding an optional key does not need a bump". That rule reasons
    # about READABILITY: an old key set is still readable by a new build, which
    # remains true here (absent key -> [] -> not cash-tracked -> exactly today's
    # behaviour, so back-compat in that direction is structural). The reverse
    # direction is the trap, because a SUCCESSFUL READ is the failure mode: the
    # file parses, the import "works", and the money is gone. A refusal is the
    # only honest outcome, so the version has to move.
    def self.native_version(cash:)
      cash ? NATIVE_VERSION_CASH : NATIVE_VERSION_BASE
    end

    # Broker holdings snapshot (the user-supplied Wealthsimple report shape).
    HOLDINGS_CSV_FORMAT = "wealthsimple.holdings".freeze

    # Broker ACTIVITY ledger (backlog #068) — a real transaction history, unlike
    # the snapshot above. Prefer this format when a user has both.
    ACTIVITIES_CSV_FORMAT = "wealthsimple.activities".freeze

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

    # One liquid-cash movement (issue #80). `amount` is SIGNED, exactly as the
    # column stores it and exactly as the wire carries it: deposit > 0,
    # withdrawal < 0, and the four internal kinds either way but never zero.
    # There is no magnitude->sign conversion anywhere in this pipeline — a
    # broker's negative dividend_cash (a reversal) and positive tax (a refund)
    # must survive a round trip unchanged, and `.abs` anywhere here would destroy
    # exactly that.
    CashSpec = Data.define(:kind, :amount, :occurred_on, :notes)

    # `warnings` are per-portfolio, non-fatal notes (a dropped short position, a
    # benchmark that doesn't exist here). They are surfaced to the user rather
    # than swallowed — a silent partial import is the failure mode this feature
    # can least afford.
    PortfolioSpec = Data.define(
      :name, :benchmark_name, :transactions, :recurring_transactions, :warnings, :cash_transactions
    ) do
      # `cash_transactions` defaults for the same reason Document#splits does:
      # every pre-#80 parser and test constructs a PortfolioSpec without naming a
      # member it never produces, and a required member would break them all at
      # once for no gain. An absent cash section means "this portfolio does not
      # track cash", which is precisely what an empty array yields.
      def initialize(cash_transactions: [], **rest)
        super(cash_transactions: cash_transactions, **rest)
      end
    end

    # An instrument-global corporate action (backlog #068). NOT per portfolio:
    # `split_events` is keyed on (instrument_id, ex_date) and every portfolio
    # holding the instrument sees the same ratio, which is what makes
    # Holdings::Calculator's "split applies at the START of its ex-date" sweep
    # correct. Import therefore writes these OUTSIDE any portfolio savepoint, and
    # before any transaction — Positions::Validator reads splits from the database
    # while replaying, so a sell of post-split shares would be rejected if the
    # split were not already there.
    SplitSpec = Data.define(:symbol, :ex_date, :ratio)

    Document = Data.define(:format, :instruments, :portfolios, :warnings, :splits) do
      # `splits` defaults so the two pre-#068 parsers (and their tests) keep
      # constructing a Document without naming a member they never produce.
      def initialize(splits: [], **rest)
        super(splits: splits, **rest)
      end

      # symbol (upcased) => InstrumentSpec
      def instrument_index
        instruments.index_by { |spec| spec.symbol.upcase }
      end
    end
  end
end
