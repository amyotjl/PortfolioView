module Api
  module V1
    # Portfolios CRUD (backlog #027, docs/PLAN.md § API contract):
    # POST/GET/PATCH/DELETE /api/v1/portfolios(/:id), always scoped to
    # Current.user. A portfolio that is missing or belongs to another user is
    # the same 404 envelope (BaseController's RecordNotFound rescue) — never a
    # 403, so probing can't confirm existence.
    class PortfoliosController < BaseController
      before_action :set_portfolio, only: %i[ show update destroy ]

      # Two racing creates/renames can both pass the uniqueness validation and
      # hit UNIQUE (user_id, name) at the DB; map that to the same 422 the
      # validation produces. name is the only unique constraint this controller
      # can trip (benchmark_id existence is validated before the write).
      rescue_from ActiveRecord::RecordNotUnique do
        render_error(
          code: "validation_failed",
          message: "Validation failed.",
          status: :unprocessable_entity,
          details: { name: [ "has already been taken" ] }
        )
      end

      # GET /api/v1/portfolios
      def index
        portfolios = Current.user.portfolios.order(:created_at, :id)
        render json: { portfolios: portfolios.map { |p| PortfolioSerializer.new(p).as_json } }
      end

      # GET /api/v1/portfolios/:id
      def show
        render json: { portfolio: PortfolioSerializer.new(@portfolio).as_json }
      end

      # POST /api/v1/portfolios
      def create
        portfolio = Current.user.portfolios.new(portfolio_params)

        if portfolio.save
          render json: { portfolio: PortfolioSerializer.new(portfolio).as_json }, status: :created
        else
          render_validation_errors portfolio
        end
      end

      # PATCH /api/v1/portfolios/:id
      def update
        if @portfolio.update(portfolio_params)
          render json: { portfolio: PortfolioSerializer.new(@portfolio).as_json }
        else
          render_validation_errors @portfolio
        end
      end

      # DELETE /api/v1/portfolios/:id — the portfolios FK graph (ON DELETE
      # CASCADE) removes dependent transactions and recurring rules with the row.
      def destroy
        @portfolio.destroy!
        head :no_content
      end

      private

      def set_portfolio
        @portfolio = Current.user.portfolios.find(params[:id])
      end

      def portfolio_params
        params.permit(:name, :benchmark_id)
      end
    end
  end
end
