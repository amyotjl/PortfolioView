# Hand-rolled serializer PORO (no jbuilder/AMS) — presentation layer only.
# One curated benchmark: id (what portfolios reference), display name, and the
# underlying ETF symbol (backlog #027: symbol + name + id).
class BenchmarkSerializer
  def initialize(benchmark)
    @benchmark = benchmark
  end

  def as_json(*)
    {
      id: @benchmark.id,
      name: @benchmark.name,
      symbol: @benchmark.instrument.symbol
    }
  end
end
