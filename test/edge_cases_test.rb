# frozen_string_literal: true

require "test_helper"

class EdgeCasesTest < BouncyTest
  test "partial provider recovery is audited and retains local evidence" do
    observe
    outcomes = [{ "email" => "Ada@Example.com", "result" => "failed" }]
    @provider.stub(:release, ->(*) { raise Bouncy::ReleaseFailed.new("partial", outcomes: outcomes) }) do
      assert_raises(Bouncy::ReleaseFailed) { Bouncy.release!("ada@example.com", note: "Recovery") }
    end
    assert_equal outcomes, Bouncy.events.where(kind: "release_failed").sole.details["outcomes"]
    assert Bouncy.blocked?("ada@example.com")
  end

  test "a missing case variant needs exact absence confirmation even when another variant remains" do
    @provider.entries = [entry, entry("ADA@example.com", reason: :complaint)]
    Bouncy.sync!
    @provider.entries = [entry]
    @provider.stub(:lookup, :present) { Bouncy.sync! }
    assert_equal 2, Bouncy::Suppression.first.provider_entries.size
    assert_equal :complaint, Bouncy.status("ada@example.com").reason
  end

  test "far future events are diagnostic evidence only" do
    observe(time: 1.day.from_now)
    refute Bouncy.blocked?("ada@example.com")
    assert Bouncy.events.sole.details["ignored_for_policy"]
  end

  test "status exposes observed provider age and most recent event" do
    @provider.entries = [entry]
    Bouncy.sync!
    status = Bouncy.status("ada@example.com")
    assert_equal :observed, status.knowledge
    refute status.stale?
    assert status.release_supported?
    assert_in_delta 1.day.ago.to_f, status.provider_updated_at.to_f, 1
    assert_equal "sync_added", status.last_event.kind
    assert_equal Bouncy.scope, status.scope
    assert_equal :ses, status.provider
    assert_nil Bouncy.status("unknown@example.com").last_event
  end

  test "partial additions preserve known variants and foreign snapshots fail" do
    @provider.entries = [entry]
    Bouncy.sync!
    @provider.complete = false
    @provider.entries = [entry("ADA@example.com")]
    Bouncy.sync!
    assert_equal 2, Bouncy::Suppression.first.provider_entries.size
    @provider.scope = "foreign"
    assert_raises(Bouncy::UnsafeSnapshot) { Bouncy.sync! }
    refute Bouncy.last_sync.details["complete"]
    assert Bouncy.last_successful_sync.details["complete"]
  end

  test "a repeated snapshot predating release cannot reapply its restriction" do
    stale = entry
    @provider.entries = [stale]
    Bouncy.sync!
    Bouncy.release!("ada@example.com", note: "Recovery")
    @provider.entries = [stale]
    Bouncy.sync!
    refute Bouncy.blocked?("ada@example.com")
  end

  test "a provider lookup still present prevents removal by list absence" do
    @provider.entries = [entry]
    Bouncy.sync!
    @provider.entries = []
    @provider.stub(:lookup, :present) { Bouncy.sync! }
    assert Bouncy.blocked?("ada@example.com")
  end

  test "concurrent local change during absence check wins" do
    @provider.entries = [entry]
    Bouncy.sync!
    @provider.entries = []
    @provider.stub(:lookup, lambda { |_email|
      Bouncy.block!("ada@example.com", note: "Concurrent hold")
      :absent
    }) { Bouncy.sync! }
    assert_includes Bouncy.status("ada@example.com").reasons, :hard_bounce
  end

  test "recipientless diagnostics persist without state rows" do
    observe(nil, kind: "ignored")
    assert_equal 1, Bouncy.events.count
    assert_empty Bouncy::Suppression.all
  end

  test "ordinary SQL bugs are not disguised as fail open outages" do
    Bouncy::Suppression.stub(:find_by, ->(*) { raise ActiveRecord::StatementInvalid, "bad SQL" }) do
      assert_raises(ActiveRecord::StatementInvalid) { Bouncy.status("ada@example.com") }
    end
  end

  test "local file SQLite locks and unsupported adapters have explicit behavior" do
    connection = ActiveRecord::Base.connection
    connection.stub(:adapter_name, "Unsupported") do
      assert_raises(Bouncy::ConfigurationError) { Bouncy.sync! }
    end
  end

  test "store retries a unique race outside the aborted transaction" do
    original = Bouncy::Suppression.method(:find_or_create_by!)
    calls = 0
    Bouncy::Suppression.stub(:find_or_create_by!, lambda { |*args, **kwargs, &block|
      calls += 1
      raise ActiveRecord::RecordNotUnique if calls == 1

      original.call(*args, **kwargs, &block)
    }) { Bouncy.block!("ada@example.com", note: "race") }
    assert_equal 2, calls
    assert Bouncy.blocked?("ada@example.com")
    Bouncy::Suppression.stub(:find_or_create_by!, ->(*) { raise ActiveRecord::RecordNotUnique }) do
      assert_raises(ActiveRecord::RecordNotUnique) { Bouncy.block!("ada@example.com", note: "failed") }
    end
  end
end
