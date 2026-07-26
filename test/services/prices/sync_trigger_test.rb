require "test_helper"

module Prices
  # issue #56: the shared dedupe lease behind both sync-trigger endpoints.
  class SyncTriggerTest < ActiveSupport::TestCase
    include ActiveJob::TestHelper

    test "the first trigger claims the lease and enqueues DailySyncJob" do
      result = nil

      assert_enqueued_with(job: Prices::DailySyncJob) do
        result = Prices::SyncTrigger.call(source: "test")
      end

      assert_equal :enqueued, result.status
      assert result.enqueued?
      assert_not result.already_pending?
      assert result.job_id.present?
      assert_kind_of Time, result.requested_at
    end

    test "a second trigger inside the lease enqueues nothing and reports the FIRST claim's time" do
      first = travel_to(Time.utc(2026, 7, 26, 18, 0, 0)) { Prices::SyncTrigger.call(source: "test") }

      second = nil
      travel_to(Time.utc(2026, 7, 26, 18, 3, 0)) do
        assert_no_enqueued_jobs(only: Prices::DailySyncJob) do
          second = Prices::SyncTrigger.call(source: "test")
        end
      end

      assert_equal :already_pending, second.status
      assert second.already_pending?
      assert_nil second.job_id
      assert_equal first.requested_at.iso8601, second.requested_at.iso8601,
        "an already_pending result reports when the PENDING sync was claimed, not when this call arrived"
      assert_enqueued_jobs 1, only: Prices::DailySyncJob
    end

    test "many rapid triggers collapse into exactly one enqueued job" do
      results = 5.times.map { Prices::SyncTrigger.call(source: "test") }

      assert_enqueued_jobs 1, only: Prices::DailySyncJob
      assert_equal [ :enqueued, :already_pending, :already_pending, :already_pending, :already_pending ],
        results.map(&:status)
    end

    test "the lease expires, so a later trigger enqueues again" do
      travel_to(Time.utc(2026, 7, 26, 18, 0, 0)) { Prices::SyncTrigger.call(source: "test") }

      later = nil
      travel_to(Time.utc(2026, 7, 26, 18, 0, 0) + Prices::SyncTrigger::LEASE + 1.second) do
        assert_enqueued_with(job: Prices::DailySyncJob) do
          later = Prices::SyncTrigger.call(source: "test")
        end
      end

      assert_equal :enqueued, later.status
      assert_enqueued_jobs 2, only: Prices::DailySyncJob
    end

    test "the claim is a plain cache entry, so clearing it re-opens the trigger" do
      Prices::SyncTrigger.call(source: "test")
      assert Rails.cache.read(Prices::SyncTrigger::CLAIM_KEY).present?, "the claim must be observable in the cache"

      Rails.cache.delete(Prices::SyncTrigger::CLAIM_KEY)

      assert_enqueued_with(job: Prices::DailySyncJob) { Prices::SyncTrigger.call(source: "test") }
      assert_enqueued_jobs 2, only: Prices::DailySyncJob
    end

    test "a corrupted claim value degrades to now instead of raising" do
      Rails.cache.write(Prices::SyncTrigger::CLAIM_KEY, "not-a-timestamp", expires_in: 5.minutes)

      result = nil
      assert_no_enqueued_jobs(only: Prices::DailySyncJob) do
        result = Prices::SyncTrigger.call(source: "test")
      end

      assert_equal :already_pending, result.status
      assert_kind_of Time, result.requested_at
    end

    test "the result struct is frozen" do
      assert Prices::SyncTrigger.call(source: "test").frozen?
    end
  end
end
