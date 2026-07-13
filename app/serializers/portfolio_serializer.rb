# Hand-rolled serializer PORO (no jbuilder/AMS) — presentation layer only.
# benchmark_id (not a nested object): the SPA joins it against the
# GET /api/v1/benchmarks list. series_version is the client-side cache-buster
# for the candles queries (docs/PLAN.md § Caching).
class PortfolioSerializer
  def initialize(portfolio)
    @portfolio = portfolio
  end

  def as_json(*)
    {
      id: @portfolio.id,
      name: @portfolio.name,
      benchmark_id: @portfolio.benchmark_id,
      series_version: @portfolio.series_version,
      created_at: @portfolio.created_at.iso8601,
      updated_at: @portfolio.updated_at.iso8601
    }
  end
end
