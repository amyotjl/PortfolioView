module Api
  module V1
    # Liquid-cash CRUD (issue #80):
    #   CRUD /api/v1/portfolios/:portfolio_id/cash_transactions
    #
    # Its OWN endpoint, deliberately not merged into /transactions: a trade row's
    # shape has non-null symbol/side/shares/price, so a union there would throw in
    # every consumer's zod schema in dev and force guards through the whole
    # transactions table, form and sell-preflight path.
    #
    # THE SIGN CONTRACT. `amount` is SIGNED on the wire in both directions, for
    # all six kinds, stored exactly as given. NOTHING here derives or coerces the
    # sign from `kind`:
    #
    #   - `tax` and `fee` are legally either sign under one kind name (a
    #     withholding vs a refund, a charge vs a reimbursement), so an unsigned
    #     magnitude cannot express a refund — it loses information for four of
    #     the six kinds;
    #   - for deposit/withdrawal a wrong sign is already caught loudly, by the
    #     model validation mirroring the cash_transactions_amount_sign CHECK, and
    #     a 422 naming the field is the correct outcome — silently rewriting the
    #     caller's sign would turn an importer's legitimately negative
    #     dividend_cash reversal into its opposite.
    #
    # The HTML form is unsigned; it converts at the frontend composable boundary,
    # which is the only layer that needs to know about magnitudes.
    #
    # NEGATIVE CASH IS NEVER REJECTED. A buy that overdraws the account, or an
    # imported broker ledger that leaves it negative, is legal and real: the
    # balance comes back in `meta` with cash_negative set so the SPA can WARN.
    # There is no balance validation here, in the model, or in a CHECK — if a
    # 422 ever appears for "insufficient cash", that is the bug.
    #
    # Always scoped to Current.user's portfolio — a missing or cross-user
    # portfolio is the same 404 envelope as everywhere else, never a 403.
    class CashTransactionsController < BaseController
      DEFAULT_PER_PAGE = 50
      MAX_PER_PAGE = 100

      before_action :set_portfolio
      before_action :set_cash_transaction, only: %i[ update destroy ]

      # GET .../cash_transactions
      # Paginated, most-recent-first (occurred_on desc, id desc as a stable
      # tiebreaker for same-day movements) — the same convention as /transactions.
      def index
        scope = @portfolio.cash_transactions
        total_count = scope.count
        rows = scope.order(occurred_on: :desc, id: :desc)
                    .limit(per_page)
                    .offset((page - 1) * per_page)

        render json: {
          cash_transactions: rows.map { |row| CashTransactionSerializer.new(row).as_json },
          meta: {
            page: page,
            per_page: per_page,
            total_count: total_count,
            total_pages: total_count.zero? ? 0 : (total_count.to_f / per_page).ceil
          }
        }
      end

      # POST .../cash_transactions
      def create
        attrs = cash_params
        return if performed?

        row = @portfolio.cash_transactions.new(attrs)
        if row.save
          render json: { cash_transaction: CashTransactionSerializer.new(row).as_json,
                         meta: balance_meta }, status: :created
        else
          render_validation_errors row
        end
      end

      # PATCH .../cash_transactions/:id
      def update
        attrs = cash_params
        return if performed?

        if @cash_transaction.update(attrs)
          render json: { cash_transaction: CashTransactionSerializer.new(@cash_transaction).as_json,
                         meta: balance_meta }
        else
          render_validation_errors @cash_transaction
        end
      end

      # DELETE .../cash_transactions/:id — 204, no body. Removing the LAST cash
      # row flips the portfolio back onto the trade basis, which the model's
      # series_version bump takes care of rotating out of the caches.
      def destroy
        @cash_transaction.destroy!
        head :no_content
      end

      private

      def set_portfolio
        @portfolio = Current.user.portfolios.find(params[:portfolio_id])
      end

      def set_cash_transaction
        @cash_transaction = @portfolio.cash_transactions.find(params[:id])
      end

      # The balance the SPA can put straight in a toast. Computed from the same
      # CashLedger the /summary tile is computed from — end-of-day, trade-aware,
      # on the trading calendar — so the toast can never contradict the tile.
      def balance_meta
        ledger = Portfolios::CashLedger.for_portfolio(@portfolio)

        {
          cash_balance: ledger.closing_balance.round(MoneyMath::CENT_SCALE).to_s("F"),
          cash_negative: !ledger.first_negative_on.nil?,
          cash_negative_since: ledger.first_negative_on&.iso8601
        }
      end

      # Permitted attributes. `amount` is taken with its sign exactly as sent; the
      # only thing done to it is a strict decimal parse, so a non-numeric value is
      # a 422 mapped onto the field rather than ActiveRecord's silent cast to 0.
      # An ABSENT amount is left out of the attributes entirely: on create the
      # model's presence validation produces "can't be blank", and on update the
      # stored value is kept.
      def cash_params
        attrs = params.permit(:kind, :occurred_on, :notes).to_h.symbolize_keys

        amount = requested_amount
        return attrs if performed? || amount.nil?

        attrs.merge(amount: amount)
      end

      # nil when no amount was supplied; renders the 422 and returns nil when one
      # was supplied but is not a decimal number.
      def requested_amount
        raw = params[:amount]
        return nil if raw.nil? || raw.to_s.strip.empty?

        MoneyMath.decimal(raw.to_s)
      rescue ArgumentError, TypeError
        render_error(
          code: "validation_failed",
          message: "Validation failed.",
          status: :unprocessable_entity,
          details: { amount: [ "is not a number" ] }
        )
        nil
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
