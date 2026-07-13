module Api
  module V1
    # Transactions CRUD (backlog #028, docs/PLAN.md § API contract):
    #   CRUD /api/v1/portfolios/:portfolio_id/transactions
    #
    # Always scoped to Current.user's portfolio — a missing or cross-user
    # portfolio is the same 404 envelope (BaseController's RecordNotFound
    # rescue), never a 403, so probing can't confirm existence.
    #
    # POST/PATCH accept a ticker SYMBOL (not an instrument_id): it is validated
    # against the local listed_instruments directory (USD/US-exchange only in
    # v1) and find-or-created via Instruments::DirectoryResolver — the first
    # reference to a new symbol creates the Instrument, whose after_create_commit
    # fires the backfill + metadata jobs.
    #
    # Every create/update/destroy runs Positions::Validator inside the
    # Transaction model (no-short-positions guard); a violation surfaces as the
    # 422 envelope naming the first offending date. Any successful mutation bumps
    # the portfolio's series_version (Transaction model callback).
    class TransactionsController < BaseController
      DEFAULT_PER_PAGE = 50
      MAX_PER_PAGE = 100

      before_action :set_portfolio
      before_action :set_transaction, only: %i[ update destroy ]

      # GET /api/v1/portfolios/:portfolio_id/transactions
      # Paginated, most-recent-first (executed_on desc, id desc as a stable
      # tiebreaker for same-day trades).
      def index
        scope = @portfolio.transactions.includes(:instrument)
        total_count = scope.count
        transactions = scope.order(executed_on: :desc, id: :desc)
                            .limit(per_page)
                            .offset((page - 1) * per_page)

        render json: {
          transactions: transactions.map { |t| TransactionSerializer.new(t).as_json },
          meta: {
            page: page,
            per_page: per_page,
            total_count: total_count,
            total_pages: total_count.zero? ? 0 : (total_count.to_f / per_page).ceil
          }
        }
      end

      # POST /api/v1/portfolios/:portfolio_id/transactions
      def create
        instrument = resolve_instrument(required: true)
        return if performed?

        transaction = @portfolio.transactions.new(transaction_params.merge(instrument: instrument))
        if transaction.save
          render json: { transaction: TransactionSerializer.new(transaction).as_json }, status: :created
        else
          render_validation_errors transaction
        end
      end

      # PATCH /api/v1/portfolios/:portfolio_id/transactions/:id
      # symbol is optional here (editing amounts/dates without retickering); when
      # present it is re-resolved so a transaction can be moved to another
      # instrument (the model re-replays both affected positions).
      def update
        instrument = resolve_instrument(required: false)
        return if performed?

        attrs = transaction_params
        attrs = attrs.merge(instrument: instrument) if instrument

        if @transaction.update(attrs)
          render json: { transaction: TransactionSerializer.new(@transaction).as_json }
        else
          render_validation_errors @transaction
        end
      end

      # DELETE /api/v1/portfolios/:portfolio_id/transactions/:id
      # A destroy that would strand a later sell (backdated-delete) is rejected
      # by the model's before_destroy replay → 422 naming the offending date.
      def destroy
        if @transaction.destroy
          head :no_content
        else
          render_validation_errors @transaction
        end
      end

      private

      def set_portfolio
        @portfolio = Current.user.portfolios.find(params[:portfolio_id])
      end

      def set_transaction
        @transaction = @portfolio.transactions.find(params[:id])
      end

      # Resolves params[:symbol] → Instrument, rendering the 422 envelope (mapped
      # onto the `symbol` field) on any directory/validation failure. When
      # required: false and no symbol was supplied, returns nil so the caller
      # keeps the transaction's current instrument.
      def resolve_instrument(required:)
        symbol = params[:symbol].to_s.strip
        if symbol.blank?
          return nil unless required

          render_symbol_error("is required")
          return nil
        end

        result = Instruments::DirectoryResolver.call(symbol: symbol)
        return result.instrument if result.ok?

        render_symbol_error(result.error)
        nil
      end

      def render_symbol_error(message)
        render_error(
          code: "validation_failed",
          message: "Validation failed.",
          status: :unprocessable_entity,
          details: { symbol: [ message ] }
        )
      end

      def transaction_params
        params.permit(:side, :kind, :shares, :price, :fees, :executed_on, :notes)
      end

      def page
        [ params[:page].to_i, 1 ].max
      end

      def per_page
        requested = params[:per_page].to_i
        return DEFAULT_PER_PAGE if requested <= 0

        [ requested, MAX_PER_PAGE ].min
      end
    end
  end
end
