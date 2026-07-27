module Portfolios
  module Transfer
    # Writes a parsed Document into one user's account (backlog #064).
    #
    # ATOMICITY IS PER PORTFOLIO, ON PURPOSE.
    #
    # Each portfolio's rows are written inside their own savepoint. A portfolio
    # whose rows fail is rolled back whole and reported with its errors; its
    # siblings still commit. The two rejected alternatives:
    #   * all-or-nothing across the file — one bad row in one account throws away
    #     a good import of every other account.
    #   * row-by-row best effort — leaves a portfolio holding SOME of its trades,
    #     which then reports a wrong cost basis and a wrong position with no
    #     outward sign. A partially-imported portfolio is worse than an absent one.
    #
    # THREE PHASES, and the ordering matters:
    #   1. PLAN   — resolve every portfolio's target name (or decide to skip it).
    #      Pure reads, so a name conflict costs nothing.
    #   2. RESOLVE — find-or-create the Instrument rows the planned portfolios
    #      need, in the OUTER transaction. Instruments must not live inside a
    #      portfolio's savepoint: a rollback there undoes the row while the
    #      resolver still caches the object, so the row is lost outright if that
    #      portfolio was its only referrer, and otherwise gets insert-rolled-back-
    #      reinserted by the next referrer's autosave. (Rails nils the id of a
    #      record created in a rolled-back savepoint, so this degrades rather than
    #      writing a dangling FK — but one INSERT is still the correct shape.)
    #   3. WRITE  — one savepoint per portfolio.
    #
    # NOTHING IS EVER OVERWRITTEN. A name collision is resolved by renaming the
    # incoming portfolio (default) or skipping it; there is no destructive merge
    # or replace mode, so a mistaken import is always undone by deleting the
    # portfolios it created.
    #
    # Transactions are inserted in (executed_on, buys-before-sells) order because
    # the no-short-positions guard in the Transaction model replays the rows
    # committed SO FAR — a sell inserted ahead of the buy that covers it would be
    # rejected even though the file as a whole is valid.
    class Import
      ON_CONFLICT_MODES = %w[rename skip].freeze
      # Bounds the rename probe (" (imported)", " (imported 2)", ...) so a
      # pathological account name can't loop.
      MAX_RENAME_ATTEMPTS = 50

      PortfolioResult = Data.define(
        :name, :imported_as, :status, :transactions_created, :recurring_created, :errors, :warnings
      )

      Result = Data.define(:format, :dry_run, :portfolios, :totals, :warnings)

      # Aborts one portfolio's savepoint with a reportable message. Never escapes
      # #call.
      class PortfolioFailed < StandardError; end

      # One planned portfolio: the spec, the name it will actually take (nil when
      # skipped), and the notes accumulated for it so far.
      Planned = Struct.new(:spec, :name, :warnings, keyword_init: true)

      def self.call(...) = new(...).call

      def initialize(user:, document:, on_conflict: "rename", dry_run: false)
        @user = user
        @document = document
        @on_conflict = ON_CONFLICT_MODES.include?(on_conflict.to_s) ? on_conflict.to_s : "rename"
        @dry_run = ActiveModel::Type::Boolean.new.cast(dry_run) || false
        @resolver = InstrumentResolver.new(document.instruments)
      end

      def call
        results = nil
        @split_warnings = []
        @splits_created = 0

        # A dry run performs the ENTIRE real import — every model validation, the
        # position replay, the instrument creation — then rolls the outer
        # transaction back. That is what makes a preview trustworthy instead of a
        # second, weaker code path that can disagree with the real one.
        ActiveRecord::Base.transaction do
          planned = plan_portfolios
          preresolve_instruments(planned)
          # Splits BEFORE any transaction, and outside every savepoint — see
          # #create_splits.
          create_splits
          results = planned.map { |item| write_portfolio(item) }
          raise ActiveRecord::Rollback if @dry_run
        end

        Result.new(
          format: @document.format,
          dry_run: @dry_run,
          portfolios: results,
          totals: totals_for(results),
          warnings: @document.warnings + @split_warnings
        )
      end

      private

      # --- Phase 1: plan ---------------------------------------------------------

      def plan_portfolios
        # Names claimed earlier in THIS run: the unique index only sees committed
        # rows, and two accounts in one file can legitimately want one name.
        claimed = Set.new

        @document.portfolios.map do |spec|
          warnings = spec.warnings.dup
          name = target_name(spec.name, claimed, warnings)
          claimed << name if name
          Planned.new(spec: spec, name: name, warnings: warnings)
        end
      end

      # nil means "skip this portfolio".
      #
      # Warning wording is deliberately TENSE-NEUTRAL throughout this class. The
      # same strings are shown for a dry run, where nothing happened — "was
      # imported as" told preview users their data had already been written.
      def target_name(name, claimed, warnings)
        return name unless name_taken?(name, claimed)

        if @on_conflict == "skip"
          warnings << "A portfolio named “#{name}” already exists, so this one is skipped."
          return nil
        end

        available = next_available_name(name, claimed)
        if available.nil?
          warnings << "A portfolio named “#{name}” already exists and no free variant of that name is available, so this one is skipped."
          return nil
        end

        warnings << "A portfolio named “#{name}” already exists, so the imported copy is named “#{available}”."
        available
      end

      # Exact match, mirroring the UNIQUE (user_id, name) index and the model's
      # case-sensitive uniqueness validation — so we never rename a portfolio the
      # database would have accepted as-is.
      def name_taken?(name, claimed)
        claimed.include?(name) || @user.portfolios.exists?(name: name)
      end

      def next_available_name(name, claimed)
        (1..MAX_RENAME_ATTEMPTS).each do |attempt|
          candidate = attempt == 1 ? "#{name} (imported)" : "#{name} (imported #{attempt})"
          return candidate unless name_taken?(candidate, claimed)
        end
        nil
      end

      # --- Phase 2: resolve instruments -----------------------------------------

      # Runs in the outer transaction so a later per-portfolio rollback cannot
      # orphan the resolver's cache (see the class header). Failures are recorded,
      # not raised: only the portfolios that reference an unresolvable symbol
      # should fail.
      def preresolve_instruments(planned)
        symbols = planned.reject { |item| item.name.nil? }.flat_map do |item|
          item.spec.transactions.map(&:symbol) + item.spec.recurring_transactions.map(&:symbol)
        end

        symbols.map { |symbol| symbol.to_s.strip.upcase }.uniq.each { |symbol| @resolver.resolve(symbol) }
      end

      # --- Phase 2b: instrument-global corporate actions -------------------------

      # Splits are written here, in the OUTER transaction and BEFORE any
      # transaction row, for two independent reasons:
      #
      #   1. `split_events` is instrument-global (keyed on instrument_id, ex_date),
      #      so it does not belong inside a per-portfolio savepoint — a rollback
      #      there would drop an event other portfolios depend on.
      #   2. Positions::Validator reads splits FROM THE DATABASE while replaying a
      #      proposed transaction set. A sell of post-split shares would be
      #      rejected as an oversell if the split were not already committed.
      #
      # An existing event for the same (instrument, ex_date) is never overwritten:
      # provider-fetched split data is authoritative, and the same
      # don't-let-an-import-downgrade-local-data rule the instrument resolver
      # follows applies here.
      def create_splits
        @document.splits.each do |spec|
          result = @resolver.resolve(spec.symbol)
          unless result.ok?
            @split_warnings << "Split for #{spec.symbol} on #{spec.ex_date.iso8601} was skipped: " \
                               "#{result.error}."
            next
          end

          existing = SplitEvent.find_by(instrument_id: result.instrument.id, ex_date: spec.ex_date)
          if existing
            if existing.ratio != spec.ratio
              @split_warnings << "#{spec.symbol} already has a #{existing.ratio.to_s('F')}:1 split on " \
                                 "#{spec.ex_date.iso8601}, so the file's #{spec.ratio.to_s('F')}:1 was " \
                                 "ignored — existing market data wins over an imported file."
            end
            next
          end

          event = SplitEvent.new(instrument: result.instrument, ex_date: spec.ex_date, ratio: spec.ratio)
          if event.save
            @splits_created += 1
          else
            @split_warnings << "Split for #{spec.symbol} on #{spec.ex_date.iso8601} could not be recorded: " \
                               "#{messages_for(event)}."
          end
        end
      end

      # --- Phase 3: write --------------------------------------------------------

      def write_portfolio(item)
        spec = item.spec
        return skipped_result(item) if item.name.nil?

        created = { transactions: 0, recurring: 0 }

        begin
          # requires_new: a real SAVEPOINT, so this portfolio rolls back without
          # discarding siblings already written in the outer transaction.
          ActiveRecord::Base.transaction(requires_new: true) do
            portfolio = build_portfolio(spec, item.name, item.warnings)
            rules_by_key = create_recurring_rules(spec, portfolio, item.warnings)
            created[:recurring] = rules_by_key.size
            created[:transactions] = create_transactions(spec, portfolio, rules_by_key, item.warnings)
          end
        rescue PortfolioFailed => e
          return PortfolioResult.new(
            name: spec.name, imported_as: nil, status: "failed",
            transactions_created: 0, recurring_created: 0,
            errors: [ e.message ], warnings: item.warnings
          )
        end

        PortfolioResult.new(
          name: spec.name,
          imported_as: item.name,
          status: item.name == spec.name ? "created" : "renamed",
          transactions_created: created[:transactions],
          recurring_created: created[:recurring],
          errors: [],
          warnings: item.warnings
        )
      end

      def skipped_result(item)
        PortfolioResult.new(
          name: item.spec.name, imported_as: nil, status: "skipped",
          transactions_created: 0, recurring_created: 0, errors: [], warnings: item.warnings
        )
      end

      def build_portfolio(spec, name, warnings)
        portfolio = @user.portfolios.new(name: name)
        portfolio.benchmark = resolve_benchmark(spec.benchmark_name, warnings)

        unless portfolio.save
          raise PortfolioFailed, "Portfolio could not be created: #{messages_for(portfolio)}"
        end

        portfolio
      end

      # Benchmarks are a CURATED, seeded list, so a name absent here is a
      # difference between environments rather than bad data — import the
      # portfolio without one instead of failing it. The user can pick one after.
      def resolve_benchmark(benchmark_name, warnings)
        return nil if benchmark_name.blank?

        benchmark = ::Benchmark.find_by(name: benchmark_name)
        if benchmark.nil?
          warnings << "Benchmark “#{benchmark_name}” doesn’t exist in this database, so the imported portfolio has no benchmark."
        end
        benchmark
      end

      def create_recurring_rules(spec, portfolio, warnings)
        spec.recurring_transactions.each_with_object({}) do |rule_spec, by_key|
          instrument = resolve_instrument!(rule_spec.symbol, "recurring rule")

          rule = portfolio.recurring_transactions.new(
            instrument: instrument,
            side: rule_spec.side,
            amount_type: rule_spec.amount_type,
            dollar_amount: rule_spec.dollar_amount,
            share_amount: rule_spec.share_amount,
            frequency: rule_spec.frequency,
            anchor_on: rule_spec.anchor_on,
            next_run_on: rule_spec.next_run_on,
            end_on: rule_spec.end_on,
            active: rule_spec.active
          )

          unless rule.save
            raise PortfolioFailed,
                  "Recurring rule for #{rule_spec.symbol} could not be imported: #{messages_for(rule)}"
          end

          # RecurringTransaction clamps a past next_run_on forward on create, so an
          # import can't trigger months of surprise back-materialization. Say so:
          # the file's value was not honored verbatim.
          if rule_spec.next_run_on && rule.next_run_on != rule_spec.next_run_on
            warnings << "Recurring rule for #{rule_spec.symbol}: next run is moved from " \
                        "#{rule_spec.next_run_on.iso8601} to #{rule.next_run_on.iso8601} " \
                        "(a rule may not materialize into the past)."
          end

          by_key[rule_spec.key] = rule
        end
      end

      def create_transactions(spec, portfolio, rules_by_key, warnings)
        # Undated rows sort last via the leading flag (never by comparing a Date
        # to nil) so the model's presence validation is what reports them.
        ordered = spec.transactions.sort_by.with_index do |tx, index|
          [ tx.executed_on ? 0 : 1, tx.executed_on || Date.new(0), tx.side == "sell" ? 1 : 0, index ]
        end

        ordered.each_with_index.sum do |tx_spec, index|
          create_transaction(tx_spec, index, portfolio, rules_by_key, warnings)
        end
      end

      def create_transaction(tx_spec, index, portfolio, rules_by_key, warnings)
        instrument = resolve_instrument!(tx_spec.symbol, "transaction #{index + 1}")
        rule = rules_by_key[tx_spec.recurring_key] if tx_spec.recurring_key

        if tx_spec.recurring_key && rule.nil?
          warnings << "Transaction #{index + 1} (#{tx_spec.symbol}) references unknown recurring rule " \
                      "“#{tx_spec.recurring_key}”, so it is imported as a standalone transaction."
        end

        transaction = portfolio.transactions.new(
          instrument: instrument,
          side: tx_spec.side,
          kind: tx_spec.kind,
          shares: tx_spec.shares,
          price: tx_spec.price,
          fees: tx_spec.fees,
          executed_on: tx_spec.executed_on,
          notes: tx_spec.notes,
          recurring_transaction: rule,
          # Only meaningful alongside a rule: the partial unique index backing
          # materialization idempotency is [recurring_transaction_id, scheduled_for].
          scheduled_for: rule ? tx_spec.scheduled_for : nil
        )

        unless transaction.save
          raise PortfolioFailed,
                "#{describe(tx_spec, index)} could not be imported: #{messages_for(transaction)}"
        end

        1
      end

      def resolve_instrument!(symbol, context)
        result = @resolver.resolve(symbol)
        return result.instrument if result.ok?

        raise PortfolioFailed, "Symbol #{symbol.presence || '(blank)'} in #{context} #{result.error}."
      end

      def describe(tx_spec, index)
        date = tx_spec.executed_on ? " on #{tx_spec.executed_on.iso8601}" : ""
        "Transaction #{index + 1} (#{tx_spec.side} #{tx_spec.symbol}#{date})"
      end

      # `base` errors — which is where the position-guard messages land — already
      # read as full clauses, which is exactly what full_messages preserves.
      def messages_for(record)
        record.errors.full_messages.join("; ")
      end

      def totals_for(results)
        {
          portfolios_created: results.count { |r| r.status.in?(%w[created renamed]) },
          portfolios_skipped: results.count { |r| r.status == "skipped" },
          portfolios_failed: results.count { |r| r.status == "failed" },
          transactions_created: results.sum(&:transactions_created),
          recurring_created: results.sum(&:recurring_created),
          # Instrument-global, so it belongs to the run rather than to any one
          # portfolio row.
          splits_created: @splits_created
        }
      end
    end
  end
end
