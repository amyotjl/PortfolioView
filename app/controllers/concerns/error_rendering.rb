# Renders the single error envelope used by every endpoint (docs/PLAN.md § API contract):
#   { "error": { "code", "message", "details" } }
# `details` maps onto form fields for 422 responses and is {} otherwise.
module ErrorRendering
  extend ActiveSupport::Concern

  private

  def render_error(code:, message:, status:, details: {})
    render json: { error: { code: code, message: message, details: details } }, status: status
  end
end
