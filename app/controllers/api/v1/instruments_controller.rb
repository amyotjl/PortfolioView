module Api
  module V1
    # Instruments endpoints (backlog #026, docs/PLAN.md § API contract):
    #
    #   GET /api/v1/instruments/search?q=      ticker autocomplete
    #   GET /api/v1/instruments/:id/price?date= transaction-form close prefill
    #
    # Both require an authenticated session (BaseController default).
    class InstrumentsController < BaseController
      MIN_QUERY_LENGTH = 2

      # GET /api/v1/instruments/search?q=
      # Serves autocomplete from the LOCAL listed_instruments directory — by
      # design this never makes a provider HTTP call, so typing in the ticker
      # box burns zero API quota (docs/PLAN.md § Free data sources).
      def search
        q = params[:q].to_s.strip

        if q.length < MIN_QUERY_LENGTH
          return render_error(
            code: "validation_failed",
            message: "Search query is too short.",
            status: :unprocessable_entity,
            details: { q: [ "must be at least #{MIN_QUERY_LENGTH} characters" ] }
          )
        end

        results = ListedInstrument.search(q)
        render json: { instruments: results.map { |li| ListedInstrumentSerializer.new(li).as_json } }
      end

      # GET /api/v1/instruments/:id/price?date=
      # Returns the cached close for the most recent trading day <= date
      # (weekend/holiday-dated requests resolve to the prior trading day —
      # matching the UI copy that such transactions take effect the next
      # trading day, priced off the last real close). A date before the
      # instrument's price history answers 404 price_unavailable — documented
      # status, never a 500.
      def price
        instrument = Instrument.find(params[:id]) # unknown id -> 404 envelope (BaseController rescue)

        date = parse_iso_date(params[:date])
        return if performed?

        row = instrument.daily_prices.where(date: ..date).order(date: :desc).first

        if row
          render json: { price: DailyPriceSerializer.new(row).as_json }
        else
          render_error(
            code: "price_unavailable",
            message: "No cached close on or before #{date.iso8601} for this instrument.",
            status: :not_found
          )
        end
      end

      private

      # Strict ISO-8601 (YYYY-MM-DD). Renders the 422 envelope (details mapped
      # onto the date param) and returns nil when missing or malformed.
      def parse_iso_date(raw)
        Date.iso8601(raw.to_s)
      rescue Date::Error
        render_error(
          code: "validation_failed",
          message: "Date is missing or invalid.",
          status: :unprocessable_entity,
          details: { date: [ "must be an ISO-8601 date (YYYY-MM-DD)" ] }
        )
        nil
      end
    end
  end
end
