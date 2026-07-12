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
end
