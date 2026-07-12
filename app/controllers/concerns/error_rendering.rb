# Renders the single error envelope used by every endpoint (docs/PLAN.md § API contract):
#   { "error": { "code", "message", "details" } }
# `details` maps onto form fields for 422 responses and is {} otherwise.
module ErrorRendering
  extend ActiveSupport::Concern

  private

  def render_error(code:, message:, status:, details: {})
    render json: { error: { code: code, message: message, details: details } }, status: status
  end

  # Shared 404 for anything scoped to Current.user that isn't found — the same
  # response whether the record is missing or belongs to another user, so a
  # cross-user probe can't distinguish "not yours" from "doesn't exist" (no
  # existence leak; 404 not 403).
  def render_not_found(message: "The requested resource was not found.")
    render_error(code: "not_found", message: message, status: :not_found)
  end

  # 422 for a failed model save: details is the {field => [messages]} map the
  # frozen contract requires (same shape the registration endpoint already
  # emits via errors.as_json).
  def render_validation_errors(record, message: "Validation failed.")
    render_error(
      code: "validation_failed",
      message: message,
      status: :unprocessable_entity,
      details: record.errors.as_json
    )
  end
end
