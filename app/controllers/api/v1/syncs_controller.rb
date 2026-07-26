module Api
  module V1
    # The SPA's supported path to "Sync now" (issue #56, consumed by #57).
    #
    # WHY this exists alongside POST /api/internal/jobs/daily_sync: a browser
    # SPA cannot hold the internal bearer token. Any token the JS bundle can
    # read is a token every user — and every devtools panel — can read, so
    # shipping it would publish the credential that lets anyone drive the app's
    # job queue. Instead the button uses the credential the browser ALREADY has
    # and that the app already protects: the HttpOnly session cookie plus the
    # XSRF-TOKEN/X-XSRF-TOKEN pair. Same job, same dedupe lease, same error
    # envelope, zero new secrets in the client.
    #
    # The token-guarded internal route stays for cron / external callers, which
    # have no cookie jar.
    class SyncsController < BaseController
      # GET /api/v1/sync
      #
      # The global price-cache freshness snapshot #57's Settings page renders
      # ("prices are current through ..." / "a sync is needed"). Global, not
      # portfolio-scoped, and never 404s — an empty cache is a valid answer
      # (`latest_price_on: null`), not a missing resource. Always 200 for a
      # signed-in caller. See SyncStatusSerializer for the shape and
      # Prices::Freshness for the staleness rule.
      def show
        render json: SyncStatusSerializer.new(Prices::Freshness.call).as_json
      end

      # POST /api/v1/sync
      #
      # Enqueues Prices::DailySyncJob via Prices::SyncTrigger and answers 202
      # in both outcomes (`status: "enqueued"` or `"already_pending"`) — see
      # SyncSerializer. Deliberately takes no parameters: there is exactly one
      # thing to sync, and a body would only invite scope creep.
      #
      # Not rate-limited beyond the trigger's own claim lease: the lease already
      # collapses repeat clicks into one job, and it is shared with the internal
      # route, so a signed-in user cannot out-click it.
      def create
        result = Prices::SyncTrigger.call(source: "settings_ui")

        render json: SyncSerializer.new(result).as_json, status: :accepted
      end
    end
  end
end
