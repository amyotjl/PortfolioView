module Portfolios
  # The external cash ONE TRADE moves (issue #80).
  #
  # This formula lived in two hand-copied places — Valuation#external_amount and
  # Simulation#external_dollars — and the cash ledger would have made three. It
  # gets a single home because a sign error here is silent money: nothing raises,
  # nothing is nil, the dashboard just reports the wrong dollars.
  #
  #   buy  =>  + (shares x price + fees)   external cash INTO the portfolio
  #   sell =>  - (shares x price - fees)   external cash OUT of it
  #
  # ROUNDED TO THE CENT PER TRANSACTION, and callers sum the rounded figures —
  # never sum at full precision and round late. shares is numeric(20,8) and
  # price numeric(16,6), so one raw product carries up to 14 dp, while a broker's
  # cash ledger is a list of discrete cent-denominated movements and
  # frontend/src/lib/money.ts does exact integer cents. Rounding late disagrees
  # with both by pennies, which is precisely what the cash feature exists to stop.
  module TradeCash
    # Signed, in the EXTERNAL-FLOW convention: positive = cash the user pushed
    # into the portfolio. Portfolios::CashLedger therefore SUBTRACTS this from
    # the running cash balance (a buy consumes cash; a sell restores it).
    def self.for(tx)
      shares = MoneyMath.decimal(tx.shares)
      price  = MoneyMath.decimal(tx.price)
      fees   = MoneyMath.decimal(tx.fees)
      gross  = tx.side == "sell" ? -(shares * price - fees) : shares * price + fees

      MoneyMath.round_to_cents(gross)
    end

    # The same money read in the DIRECTION'S OWN sign — what
    # Benchmarks::Simulation feeds the shadow ETF: a buy deposits cost + fees, a
    # sell withdraws proceeds net of fees, both as positive dollar amounts.
    #
    # Deliberately not `.for(tx).abs`: a sell whose fees exceed its proceeds must
    # stay NEGATIVE so the simulation's `next unless dollars.positive?` guard
    # still skips it, exactly as it did before this extraction.
    def self.dollars(tx)
      amount = self.for(tx)
      tx.side == "sell" ? -amount : amount
    end
  end
end
