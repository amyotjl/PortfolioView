module Api
  module Internal
    # Bearer-token job triggers for cron / external callers (issue #56).
    #
    # The browser SPA does NOT and MUST NOT call these: shipping the token to
    # the client would publish it to every user and to devtools. The Settings
    # "Sync now" button uses the session-authenticated twin,
    # `POST /api/v1/sync` (Api::V1::SyncsController), which enqueues the same
    # job through the same Prices::SyncTrigger and therefore shares its dedupe
    # window.
    class JobsController < BaseController
      # POST /api/internal/jobs/daily_sync
      #
      # 202 Accepted in BOTH outcomes — the request was accepted and a sync
      # either was just enqueued or is already pending. The body's `status`
      # tells the caller which; see SyncSerializer.
      def daily_sync
        result = Prices::SyncTrigger.call(source: "internal_token")

        render json: SyncSerializer.new(result).as_json, status: :accepted
      end
    end
  end
end
