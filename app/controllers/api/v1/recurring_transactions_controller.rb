module Api
  module V1
    # Recurring-transactions CRUD + preview (backlog #029, docs/PLAN.md
    # § API contract):
    #   CRUD /api/v1/portfolios/:portfolio_id/recurring_transactions
    #   POST /api/v1/portfolios/:portfolio_id/recurring_transactions/preview
    #
    # Scoped to Current.user's portfolio (uniform 404, no existence leak). v1 is
    # BUY-ONLY: a sell rule is rejected 422 (RecurringTransaction model). The
    # symbol is directory-validated + find-or-created via the shared
    # Instruments::DirectoryResolver. next_run_on is server-computed from the
    # anchor and clamped forward to today (model before_validation), so nothing
    # materializes historically by surprise. Any successful CRUD mutation bumps
    # the portfolio's series_version.
    #
    # `preview` is a DRY RUN: it computes the next 3 schedule slots as a pure
    # function of frequency + anchor (reusing the model's first_slot_on_or_after
    # / next_slot_after — the same math the materializer advances through) and
    # persists nothing. Each slot also carries its trading-day-adjusted
    # execution date (first trading day >= slot, or null when the price
    # calendar does not extend that far yet).
    class RecurringTransactionsController < BaseController
      PREVIEW_COUNT = 3

      before_action :set_portfolio
      before_action :set_rule, only: %i[ show update destroy ]

      # GET .../recurring_transactions
      def index
        rules = @portfolio.recurring_transactions.includes(:instrument).order(:created_at, :id)
        render json: { recurring_transactions: rules.map { |r| RecurringTransactionSerializer.new(r).as_json } }
      end

      # GET .../recurring_transactions/:id
      def show
        render json: { recurring_transaction: RecurringTransactionSerializer.new(@rule).as_json }
      end

      # POST .../recurring_transactions
      def create
        instrument = resolve_instrument
        return if performed?

        rule = @portfolio.recurring_transactions.new(recurring_params.merge(instrument: instrument))
        # Seed next_run_on from the anchor; the model clamps it forward to the
        # first slot on/after today so a past anchor never backfills.
        rule.next_run_on ||= rule.anchor_on

        if rule.save
          bump_series_version
          render json: { recurring_transaction: RecurringTransactionSerializer.new(rule).as_json },
                 status: :created
        else
          render_validation_errors rule
        end
      end

      # PATCH .../recurring_transactions/:id
      def update
        @rule.assign_attributes(recurring_params)
        recompute_next_run_on_if_schedule_changed
        clear_pause_on_reactivation

        if @rule.save
          bump_series_version
          render json: { recurring_transaction: RecurringTransactionSerializer.new(@rule).as_json }
        else
          render_validation_errors @rule
        end
      end

      # DELETE .../recurring_transactions/:id — materialized transactions outlive
      # the rule (FK ON DELETE SET NULL); their series_version bumps already
      # happened when they were inserted.
      def destroy
        @rule.destroy!
        bump_series_version
        head :no_content
      end

      # POST .../recurring_transactions/preview — dry run, persists nothing.
      def preview
        frequency = params[:frequency].to_s
        anchor_on = parse_iso_date(params[:anchor_on])

        details = {}
        details[:frequency] = [ "is not included in the list" ] unless RecurringTransaction::FREQUENCIES.include?(frequency)
        details[:anchor_on] = [ "must be an ISO-8601 date (YYYY-MM-DD)" ] if anchor_on.nil?
        if details.any?
          return render_error(code: "validation_failed", message: "Validation failed.",
                              status: :unprocessable_entity, details: details)
        end

        render json: { preview: { run_dates: compute_run_dates(frequency, anchor_on) } }
      end

      private

      def set_portfolio
        @portfolio = Current.user.portfolios.find(params[:portfolio_id])
      end

      # Any recurring-rule mutation stales cached series (docs/PLAN.md § Caching),
      # mirroring the Transaction model's own series_version bump.
      def bump_series_version
        Portfolio.where(id: @portfolio.id).update_all("series_version = series_version + 1")
      end

      def set_rule
        @rule = @portfolio.recurring_transactions.find(params[:id])
      end

      def compute_run_dates(frequency, anchor_on)
        rule = RecurringTransaction.new(frequency: frequency, anchor_on: anchor_on)
        start_from = [ anchor_on, Trading::Calendar.today ].max

        slot = rule.first_slot_on_or_after(start_from)
        PREVIEW_COUNT.times.map do
          entry = {
            scheduled_for: slot.iso8601,
            execution_on: Trading::Calendar.first_day_on_or_after(slot)&.iso8601
          }
          slot = rule.next_slot_after(slot)
          entry
        end
      end

      # Keep next_run_on consistent when a schedule-defining attribute changes on
      # update (the model's clamp only runs on create). Mirrors create's clamp.
      def recompute_next_run_on_if_schedule_changed
        return unless @rule.will_save_change_to_anchor_on? || @rule.will_save_change_to_frequency?
        return if @rule.anchor_on.blank? || !RecurringTransaction::FREQUENCIES.include?(@rule.frequency)

        start_from = [ @rule.anchor_on, Trading::Calendar.today ].max
        @rule.next_run_on = @rule.first_slot_on_or_after(start_from)
      end

      # Resuming a paused rule clears its paused reason and skip counter.
      def clear_pause_on_reactivation
        return unless @rule.will_save_change_to_active? && @rule.active?

        @rule.paused_reason = nil
        @rule.consecutive_skips = 0
      end

      def resolve_instrument
        result = Instruments::DirectoryResolver.call(symbol: params[:symbol])
        return result.instrument if result.ok?

        render_error(code: "validation_failed", message: "Validation failed.",
                     status: :unprocessable_entity, details: { symbol: [ result.error ] })
        nil
      end

      def recurring_params
        params.permit(:side, :amount_type, :dollar_amount, :share_amount,
                      :frequency, :anchor_on, :end_on, :active)
      end

      def parse_iso_date(raw)
        Date.iso8601(raw.to_s)
      rescue Date::Error
        nil
      end
    end
  end
end
