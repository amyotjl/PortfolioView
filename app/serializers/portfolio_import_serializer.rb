# Hand-rolled serializer PORO (no jbuilder/AMS) — presentation layer only.
# The outcome of one import run (backlog #064).
#
# Deliberately verbose: an import is a bulk mutation the user cannot inspect
# before it happens, so the response is the ONLY place they learn that a
# portfolio was renamed, a benchmark dropped, a short position skipped, or a
# non-US ticker venue-suffixed. Never collapse this to a bare count.
class PortfolioImportSerializer
  def initialize(result)
    @result = result
  end

  def as_json(*)
    {
      format: @result.format,
      dry_run: @result.dry_run,
      totals: @result.totals,
      # File-level notes (e.g. a missing "As of" date) that belong to no one
      # portfolio.
      warnings: @result.warnings,
      portfolios: @result.portfolios.map { |p| portfolio_json(p) }
    }
  end

  private

  def portfolio_json(portfolio)
    {
      # `name` is what the file asked for; `imported_as` is what it actually
      # became (nil when skipped/failed). Both are needed to explain a rename.
      name: portfolio.name,
      imported_as: portfolio.imported_as,
      status: portfolio.status,
      transactions_created: portfolio.transactions_created,
      recurring_created: portfolio.recurring_created,
      # Cash rows written for this portfolio (issue #80). Reported per portfolio
      # AND in `totals` because a broker ledger's cash is most of what the user is
      # importing, and a count is the only place they can confirm it landed.
      cash_created: portfolio.cash_created,
      errors: portfolio.errors,
      warnings: portfolio.warnings
    }
  end
end
