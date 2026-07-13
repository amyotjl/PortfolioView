module Api
  module V1
    # GET /api/v1/portfolios/:id/summary (backlog #032, docs/PLAN.md § API
    # contract): lifetime stat tiles computed server-side over the FULL history
    # (never a windowed candles payload). Scoped to Current.user — a missing or
    # cross-user portfolio is the uniform 404 envelope (BaseController rescue).
    class SummariesController < BaseController
      def show
        portfolio = Current.user.portfolios.find(params[:id])
        summary = Portfolios::Summary.call(portfolio: portfolio)
        render json: { summary: PortfolioSummarySerializer.new(summary).as_json }
      end
    end
  end
end
