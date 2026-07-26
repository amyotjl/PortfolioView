# Hand-rolled serializer PORO (no jbuilder/AMS) — presentation layer only.
#
# GET /api/v1/sync — the price-cache freshness snapshot (issue #56, rendered by
# #57's Settings page):
#
#   { "sync": { "latest_price_on":    "2026-07-24" | null, // ISO date
#               "last_trading_day":   "2026-07-24" | null, // ISO date
#               "stale":              false,               // never null
#               "instruments_behind": 0,                   // integer, never null
#               "pending":            false,               // never null
#               "requested_at":       null } }             // ISO-8601 UTC | null
#
# `instruments_behind` (issue #59) is the signal `stale` structurally cannot
# give: `stale` compares the MAX over referenced instruments, and SPY is always
# in that set, so ONE ticker whose fetch failed can never move it. The count
# can. `stale: false, instruments_behind: 1` is a real and meaningful state —
# "the cache as a whole is current, one symbol is not".
#
# NOTE the deliberate asymmetry with SyncSerializer: GET and POST share the
# `sync` wrapper but NOT the inner key set — GET is a state snapshot, POST is
# an action result ({status, requested_at}). POST's shape was frozen before
# this endpoint existed and is being coded against, so it was not reshaped to
# match. Two zod schemas, not one.
#
# `requested_at` means the same thing in both: when the currently-pending sync
# was claimed. Here it is null exactly when `pending` is false.
class SyncStatusSerializer
  def initialize(freshness)
    @freshness = freshness
  end

  def as_json(*)
    {
      sync: {
        latest_price_on: @freshness.latest_price_on&.iso8601,
        last_trading_day: @freshness.last_trading_day&.iso8601,
        stale: @freshness.stale,
        instruments_behind: @freshness.instruments_behind,
        pending: @freshness.pending?,
        requested_at: @freshness.pending_since&.utc&.iso8601
      }
    }
  end
end
