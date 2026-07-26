# Hand-rolled serializer PORO (no jbuilder/AMS) — presentation layer only.
#
# The shared body of BOTH sync-trigger endpoints (issue #56):
# `POST /api/internal/jobs/daily_sync` (bearer token) and `POST /api/v1/sync`
# (session + CSRF, what the Settings "Sync now" button calls). Identical shape
# on purpose, so the UI never has to care which door it came through.
#
#   { "sync": { "status": "enqueued" | "already_pending",
#               "requested_at": "2026-07-26T18:04:11Z" } }
#
# `requested_at` is the moment the CURRENTLY PENDING sync was claimed — on an
# `already_pending` response that is the ORIGINAL trigger's time, not this
# request's, which is exactly what a UI needs to say "a sync requested at
# 14:03 is already running".
class SyncSerializer
  def initialize(result)
    @result = result
  end

  def as_json(*)
    {
      sync: {
        status: @result.status.to_s,
        requested_at: @result.requested_at.utc.iso8601
      }
    }
  end
end
