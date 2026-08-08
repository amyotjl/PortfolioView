# Strict BigDecimal coercion for the money math (docs/PLAN.md § Database
# schema: "All money/shares are numeric, never float").
#
# Every domain service funnels externally supplied numbers through
# MoneyMath.decimal so a Float can never silently enter a computation: floats
# RAISE instead of being converted, because BigDecimal(float.to_s) would
# launder binary rounding error into "exact" decimals and hide the bug the
# invariant exists to prevent. Values read from Postgres numeric columns are
# already BigDecimal and pass straight through.
module MoneyMath
  # Money is denominated in whole cents everywhere it crosses a boundary a human
  # or a broker reads (issue #80).
  CENT_SCALE = 2

  module_function

  def decimal(value)
    case value
    when BigDecimal then value
    when Integer then BigDecimal(value)
    when String then BigDecimal(value)
    when Float
      raise TypeError, "Float is not allowed in money math (got #{value.inspect}); use BigDecimal or String"
    else
      raise TypeError, "cannot coerce #{value.class} into BigDecimal for money math"
    end
  end

  # Round a money figure to the CENT, returning a BigDecimal still denominated
  # in dollars (never integer cents — the domain arithmetic stays in dollars).
  # BigDecimal#round is ROUND_HALF_UP by default, the same mode the serializers
  # already use, so a figure rounded here and re-rounded at the wire is stable.
  #
  # Exists so the per-transaction cent rounding the cash ledger depends on
  # (issue #80: shares numeric(20,8) x price numeric(16,6) is up to 14 dp, while
  # a broker's ledger and frontend/src/lib/money.ts are both exact cents) has
  # ONE home instead of a scattering of `.round(2)` — where a missing call is a
  # penny of silent drift rather than an error.
  def round_to_cents(value)
    decimal(value).round(CENT_SCALE)
  end
end
