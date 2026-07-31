require "test_helper"

# Where the catch-up is hooked is as load-bearing as what it does (issue #55),
# and no unit test of the service itself can see it.
class BootCatchUpInitializerTest < ActiveSupport::TestCase
  SOURCE = Rails.root.join("config/initializers/boot_catch_up.rb")

  test "the initializer exists and gates on Boot::Eligibility before calling Boot::CatchUp" do
    src = SOURCE.read

    assert_match(/Boot::Eligibility\.eligible\?/, src)
    assert_match(/Boot::CatchUp\.call/, src)
    assert_operator src.index("Boot::Eligibility.eligible?"), :<, src.index("Boot::CatchUp.call"),
                    "the eligibility gate must come first — everything else runs in db:migrate too"
  end

  test "it hooks after_initialize (once per process), never to_prepare (once per code reload)" do
    src = SOURCE.read

    assert_match(/config\.after_initialize/, src)
    assert_no_match(/config\.to_prepare/, src,
                    "to_prepare re-runs on every development reload, which would re-enqueue the sync on every file save")
  end
end
