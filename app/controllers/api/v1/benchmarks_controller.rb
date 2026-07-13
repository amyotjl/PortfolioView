module Api
  module V1
    # GET /api/v1/benchmarks (backlog #027): the curated seeded list backing
    # the portfolio-form benchmark selector. Requires an authenticated session
    # (BaseController default). Ordered by id — the seed order (SPY, VTI, QQQ).
    class BenchmarksController < BaseController
      def index
        benchmarks = ::Benchmark.includes(:instrument).order(:id)
        render json: { benchmarks: benchmarks.map { |b| BenchmarkSerializer.new(b).as_json } }
      end
    end
  end
end
