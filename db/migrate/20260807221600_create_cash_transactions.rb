# Liquid cash (issue #80) gets its OWN TABLE rather than a widened
# `transactions`, and the deciding argument is not "three CHECKs would need
# relaxing" — it is what relaxing them costs. `transactions` CHECKs
# `shares > 0` and `price > 0`; admitting cash rows that never carry those
# columns would force both to `shares IS NULL OR shares > 0`, and *a CHECK
# passes on NULL*. Those two guards would stop protecting real trades in order
# to admit rows with nothing to protect. Secondary: seven read paths
# (Holdings::Calculator, Candles::Cache#instrument_ids, Export#instrument_specs,
# TransactionSerializer, Positions::Validator, Benchmarks::Simulation,
# Valuation#sweep) have no instrument_id filter today, and six of the seven
# would degrade *silently* rather than raise.
#
# `amount` is STORED SIGNED, so the balance is one SUM and a dividend reversal
# is representable. The wire contract is the other way round — an unsigned
# magnitude plus `kind` — and the conversion lives at the controller boundary,
# not here. The sign CHECK pins the two external kinds (deposit > 0,
# withdrawal < 0) and lets the four internal kinds carry either sign, because
# real ledgers contain dividend reversals and tax refunds. Zero is rejected
# outright: a zero-dollar movement is a parse failure, not a fact.
#
# `occurred_on`, deliberately NOT `executed_on` — a CashTransaction must never
# duck-type as a Transaction inside Holdings::Calculator / Positions::Validator
# / Benchmarks::Simulation, all of which take injectable arrays and read
# `.executed_on`. A different name makes an accidental mix a NoMethodError in a
# test rather than a wrong dollar figure in production.
#
# NEGATIVE CASH IS LEGAL BY DESIGN. There is deliberately no balance CHECK, no
# non-negative constraint and no trigger. An imported broker ledger can
# legitimately leave a portfolio negative — recorded withdrawals and trades
# drawing more than the recorded deposits — and the decision is to SHOW that
# with a warning, never to reject the row. The sign CHECK below constrains each
# row's own direction only; it says nothing about the running balance, and
# nothing in this schema may.
#
# No `portfolios.cash_balance` column, ever: the balance is a pure function of
# these rows plus `transactions`, so it cannot drift. A denormalized column
# would need invalidation on every cash insert/update/delete, every buy, every
# sell, every fee edit and every import rollback — and when it drifts it drifts
# silently into the exact number the user is reconciling against their bank.
#
# Lock analysis is trivial, and stated as such rather than dressed up: CREATE
# TABLE on a new relation locks nothing; the inline FK takes a sub-millisecond
# ShareRowExclusiveLock on `portfolios` (119 rows); the child table is empty by
# construction so both CHECKs validate over zero rows. NOT VALID/VALIDATE buys
# nothing here, and CREATE INDEX CONCURRENTLY would actively hurt — it cannot
# run inside Rails' transactional DDL.
class CreateCashTransactions < ActiveRecord::Migration[8.1]
  def change
    create_table :cash_transactions do |t|
      # User-owned (via portfolio): cascade, matching transactions and
      # recurring_transactions. The rule in this schema is ownership, not
      # depth — cascade from an owner to data that has no meaning without it,
      # restrict to protect shared reference data (instruments, benchmarks).
      # Cash is the former. No standalone portfolio_id index: the
      # (portfolio_id, occurred_on) index below covers the FK leftmost.
      t.references :portfolio, null: false, index: false,
                   foreign_key: { on_delete: :cascade }

      t.string :kind, null: false
      # Money: numeric(12,2), the same type as transactions.fees. SIGNED.
      t.decimal :amount, precision: 12, scale: 2, null: false
      t.date :occurred_on, null: false
      t.text :notes

      t.timestamps

      # The `::text` casts on the string literals are deliberate and MEASURED,
      # not decoration. `kind IN ('deposit', …)` on a varchar column parses to
      # `(kind)::text = ANY ((ARRAY[…varchar])::text[])`, which pg_get_constraintdef
      # dumps as `ARRAY['deposit'::character varying, …]::text[]` — and re-parsing
      # that dumped string yields the *per-element* cast form instead. The
      # constraint text therefore differs between a database built by
      # `db:migrate` and one built by `db:schema:load`, so `db:migrate` →
      # `db:rollback` → `db:migrate` is byte-identical on the first kind of
      # database and NOT on the second. Casting the literals to text up front
      # makes the stored form a parse fixed point, so the round trip holds
      # regardless of how the database was created. (The five pre-existing
      # CHECK-bearing tables have the same latent divergence; their schema.rb
      # lines merely happen to already sit on the load-side form.)
      t.check_constraint <<~SQL.squish, name: "cash_transactions_kind_check"
        kind::text IN ('deposit'::text, 'withdrawal'::text, 'interest'::text,
                       'dividend_cash'::text, 'tax'::text, 'fee'::text)
      SQL
      t.check_constraint <<~SQL.squish, name: "cash_transactions_amount_sign"
        (kind::text = 'deposit'::text    AND amount > 0) OR
        (kind::text = 'withdrawal'::text AND amount < 0) OR
        (kind::text NOT IN ('deposit'::text, 'withdrawal'::text) AND amount <> 0)
      SQL
    end

    # ONE index. (portfolio_id, occurred_on) serves balance-as-of, range sums,
    # the per-day series and the ledger list, and covers the FK. Measured: the
    # cash aggregation is 1.1 ms at 1,666 rows against a valuation sweep that
    # already reads 175k daily_prices rows, so a covering index is not
    # warranted. This repo already dropped index_listed_instruments_on_end_date
    # after measuring an idx_scan delta of 0; do not add a speculative one back.
    #
    # No UNIQUE: two identical $100 deposits on one day are two real bank
    # transfers, not a duplicate.
    add_index :cash_transactions, [ :portfolio_id, :occurred_on ]
  end
end
