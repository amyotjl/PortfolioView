require "test_helper"
require "fugit"

# Guards the real Solid Queue schedule (docs/PLAN.md § Price pipeline / M2):
# daily x7 pinned to America/New_York, weekly directory import, monthly metadata
# refresh, and the generated hourly finished-jobs cleanup task kept intact.
class RecurringScheduleTest < ActiveSupport::TestCase
  CONFIG = YAML.load_file(Rails.root.join("config/recurring.yml")).fetch("production").freeze

  test "keeps the generated hourly finished-jobs cleanup task" do
    task = CONFIG.fetch("clear_solid_queue_finished_jobs")
    assert_match(/clear_finished_in_batches/, task["command"])
    assert_equal "every hour at minute 12", task["schedule"]
  end

  test "daily price sync runs daily x7 pinned to America/New_York" do
    task = CONFIG.fetch("daily_price_sync")
    assert_equal "Prices::DailySyncJob", task["class"]

    schedule = task["schedule"]
    assert_includes schedule, "America/New_York", "the schedule must pin the timezone"
    assert Fugit.parse_cron(schedule), "schedule must be a valid cron"

    fields = schedule.split
    assert_equal "*", fields[4], "day-of-week must be unrestricted (daily x7, not a weekday mask)"
    assert_equal "*", fields[2], "day-of-month must be unrestricted (every day)"
  end

  test "instrument metadata refresh runs monthly pinned to America/New_York" do
    task = CONFIG.fetch("instrument_metadata_refresh")
    assert_match(/Instruments::MetadataJob\.refresh_all/, task["command"])

    schedule = task["schedule"]
    assert_includes schedule, "America/New_York"
    assert Fugit.parse_cron(schedule), "schedule must be a valid cron"
    assert_equal "1", schedule.split[2], "day-of-month must be the 1st (monthly)"
  end

  test "directory import runs weekly pinned to America/New_York" do
    task = CONFIG.fetch("directory_import")
    assert_equal "Directory::ImportJob", task["class"]

    schedule = task["schedule"]
    assert_includes schedule, "America/New_York"
    assert Fugit.parse_cron(schedule), "schedule must be a valid cron"
    assert_equal "0", schedule.split[4], "day-of-week must select a single day (weekly)"
  end

  test "recurring materializer runs nightly x7 pinned to America/New_York (backlog #023)" do
    task = CONFIG.fetch("recurring_materializer")
    assert_equal "Recurring::MaterializeDueJob", task["class"]

    schedule = task["schedule"]
    assert_includes schedule, "America/New_York", "the schedule must pin the timezone"
    assert Fugit.parse_cron(schedule), "schedule must be a valid cron"

    fields = schedule.split
    assert_equal "*", fields[4], "day-of-week must be unrestricted (daily x7, not a weekday mask)"
    assert_equal "*", fields[2], "day-of-month must be unrestricted (every day)"
  end
end
