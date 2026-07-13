module Api
  module V1
    # GET /api/v1/portfolios/:id/allocations (backlog #032, docs/PLAN.md § API
    # contract): by_instrument + by_sector pie data as-of the latest trading day,
    # ETFs/funds bucketed under "ETF / Fund". Scoped to Current.user — a missing
    # or cross-user portfolio is the uniform 404 envelope (BaseController rescue).
    class AllocationsController < BaseController
      def show
        portfolio = Current.user.portfolios.find(params[:id])
        allocations = Portfolios::Allocations.call(portfolio: portfolio)
        render json: { allocations: PortfolioAllocationsSerializer.new(allocations).as_json }
      end
    end
  end
end
