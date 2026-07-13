module Api
  module V1
    # Holdings pre-flight (backlog #030, docs/PLAN.md § API contract):
    #   GET /api/v1/portfolios/:portfolio_id/holdings?instrument_id=&as_of=
    #
    # Returns the SPLIT-ADJUSTED share count of one instrument held as of a
    # date, computed via Holdings::Calculator. It powers the sell-form warning
    # ("you hold N shares"); the server-side Positions::Validator remains
    # authoritative on submit, so this is advisory only.
    #
    # `as_of` defaults to today (America/New_York). It resolves to the effective
    # trading day = last trading day on/before as_of (a weekend/holiday as_of
    # reads the prior close — matching the "takes effect the next trading day"
    # transaction-form copy). An unknown instrument or a flat/zero position is a
    # well-formed zero-shares response (200), never a 404 — probing for a
    # position must not differ from probing for an instrument.
    class HoldingsController < BaseController
      before_action :set_portfolio

      # GET .../holdings
      def show
        instrument_id = parse_instrument_id
        return if performed?

        as_of = resolve_as_of
        return if performed?

        render json: {
          holding: {
            instrument_id: instrument_id,
            as_of: as_of.iso8601,
            shares: shares_as_of(instrument_id, as_of).to_s("F")
          }
        }
      end

      private

      def set_portfolio
        @portfolio = Current.user.portfolios.find(params[:portfolio_id])
      end

      def shares_as_of(instrument_id, as_of)
        effective = Trading::Calendar.last_day_on_or_before(as_of) || Trading::Calendar.last_day
        return BigDecimal(0) if effective.nil?

        result = Holdings::Calculator.call(portfolio: @portfolio, from: effective, to: effective)
        result.holdings.dig(effective, instrument_id) || BigDecimal(0)
      end

      # instrument_id is required; a missing/non-integer value is a 422 mapped
      # onto the field. A well-formed-but-unknown id is NOT an error here — it
      # simply yields a zero-shares response.
      def parse_instrument_id
        raw = params[:instrument_id].to_s.strip
        return Integer(raw) if raw.match?(/\A\d+\z/)

        render_error(code: "validation_failed", message: "Validation failed.",
                     status: :unprocessable_entity,
                     details: { instrument_id: [ "is required" ] })
        nil
      end

      # Defaults to today (America/New_York) when omitted; a malformed value is
      # a 422 mapped onto as_of.
      def resolve_as_of
        raw = params[:as_of].to_s.strip
        return Trading::Calendar.today if raw.blank?

        Date.iso8601(raw)
      rescue Date::Error
        render_error(code: "validation_failed", message: "Validation failed.",
                     status: :unprocessable_entity,
                     details: { as_of: [ "must be an ISO-8601 date (YYYY-MM-DD)" ] })
        nil
      end
    end
  end
end
