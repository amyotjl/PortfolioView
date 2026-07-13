module Api
  module V1
    # GET /api/v1/portfolios/:id/candles?from&to&benchmark=true (backlog #031,
    # docs/PLAN.md § API contract). Returns portfolio candles, the benchmark as a
    # close-value line, daily flows, server-computed drawdown, and meta flags —
    # served through the #033 key-rotation cache (Candles::Cache), which skips the
    # whole valuation recompute on a hit and never caches a partial response.
    #
    # `from`/`to` are optional ISO dates: absent `to` defaults to the last trading
    # day, absent `from` to the portfolio's inception. A malformed date is a 422
    # mapped onto that field. Scoped to Current.user — a missing or cross-user
    # portfolio is the uniform 404 envelope (BaseController rescue).
    class CandlesController < BaseController
      def show
        portfolio = Current.user.portfolios.find(params[:id])

        to = parse_date(params[:to], :to) || default_to
        return if performed?
        from = parse_date(params[:from], :from) || default_from(portfolio, to)
        return if performed?

        benchmark_id = benchmark_requested? ? portfolio.benchmark_id : nil

        payload = Candles::Cache.fetch(portfolio: portfolio, from: from, to: to, benchmark_id: benchmark_id) do
          report = Portfolios::CandlesReport.call(
            portfolio: portfolio, from: from, to: to, with_benchmark: benchmark_id.present?
          )
          CandlesSerializer.new(report).as_json
        end

        render json: payload
      end

      private

      def benchmark_requested?
        ActiveModel::Type::Boolean.new.cast(params[:benchmark])
      end

      # Absent -> nil (caller supplies a default); present-but-malformed -> 422
      # mapped onto the offending field, returning nil.
      def parse_date(raw, field)
        return nil if raw.blank?

        Date.iso8601(raw.to_s)
      rescue Date::Error
        render_error(
          code: "validation_failed",
          message: "#{field} is not a valid date.",
          status: :unprocessable_entity,
          details: { field => [ "must be an ISO-8601 date (YYYY-MM-DD)" ] }
        )
        nil
      end

      def default_to
        Trading::Calendar.last_day || Trading::Calendar.today
      end

      def default_from(portfolio, to)
        portfolio.transactions.minimum(:executed_on) || to
      end
    end
  end
end
