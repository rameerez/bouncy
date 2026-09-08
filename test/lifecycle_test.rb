# frozen_string_literal: true

require "test_helper"

class LifecycleTest < BouncyTest
  test "imports an address without a user and releases all exact case variants" do
    @provider.entries = [entry, entry("ADA@example.com", reason: :complaint)]
    Bouncy.sync!
    assert Bouncy.blocked?(" ada@EXAMPLE.com ")
    assert_equal :complaint, Bouncy.status("ada@example.com").reason
    Bouncy.release!("ada@example.com", note: "Verified recovery")
    assert_equal ["Ada@Example.com", "ADA@example.com"], @provider.deleted
    refute Bouncy.blocked?("ada@example.com")
    assert Bouncy::Suppression.first.released_before
    Bouncy.sync!
    refute Bouncy.blocked?("ada@example.com")
  end

  test "manual policy survives provider removal and local release preserves provider evidence" do
    @provider.entries = [entry]
    Bouncy.sync!
    Bouncy.block!("ada@example.com", note: "Support hold")
    assert_equal %i[manual hard_bounce], Bouncy.status("ada@example.com").reasons
    Bouncy.release!("ada@example.com", at: :local)
    assert_equal [:hard_bounce], Bouncy.status("ada@example.com").reasons
    assert_empty @provider.deleted
    Bouncy.block!("ada@example.com", note: "Keep this")
    @provider.entries = []
    Bouncy.sync!
    assert_equal [:manual], Bouncy.status("ada@example.com").reasons
    assert_includes @provider.lookups, "Ada@Example.com"
  end

  test "partial enumeration cannot clear evidence or authorize release" do
    @provider.entries = [entry]
    Bouncy.sync!
    @provider.entries = []
    @provider.complete = false
    refute Bouncy.sync!.details["complete"]
    assert Bouncy.blocked?("ada@example.com")
    assert_raises(Bouncy::UnsafeSnapshot) { Bouncy.release!("ada@example.com", note: "Recovery") }
    assert Bouncy.blocked?("ada@example.com")
  end

  test "unsupported policy is observation only" do
    @provider.entries = [entry]
    @provider.policy_verified = false
    refute Bouncy.sync!.details["complete"]
    refute Bouncy.blocked?("ada@example.com")
    assert_equal 1, Bouncy::Suppression.first.provider_entries.size
  end

  test "release fences survive pruning and permit genuinely newer failures" do
    travel_to(Time.utc(2026, 1, 10)) do
      observe(time: 2.minutes.ago)
      Bouncy.release!("ada@example.com", note: "Recovery")
      Bouncy.events.delete_all
      observe(time: 1.minute.ago)
      refute Bouncy.blocked?("ada@example.com")
      travel 1.second
      observe
      assert Bouncy.blocked?("ada@example.com")
    end
  end

  test "a release during list enumeration wins over stale provider evidence" do
    @provider.entries = [entry]
    Bouncy.sync!
    @provider.on_snapshot = lambda {
      @provider.on_snapshot = nil
      Bouncy.release!("ada@example.com", note: "Concurrent release")
    }
    Bouncy.sync!
    refute Bouncy.blocked?("ada@example.com")
  end

  test "a new event during remote recovery preserves local evidence" do
    observe
    @provider.on_release = -> { observe(time: 1.second.from_now) }
    assert_raises(Bouncy::ReleaseConflict) { Bouncy.release!("ada@example.com", note: "Recovery") }
    assert Bouncy.blocked?("ada@example.com")
    assert_equal "release_failed", Bouncy.events.last.kind
  end

  test "deduplication is per recipient and atomic with policy" do
    observe("ada@example.com", id: "same")
    observe("ben@example.com", id: "same")
    assert_equal :duplicate, observe("ada@example.com", id: "same")
    assert_equal 2, Bouncy.events.count
    assert_equal 2, Bouncy.blocked.count
    Bouncy::Event.stub(:create!, ->(*) { raise ActiveRecord::ConnectionNotEstablished }) do
      assert_raises(ActiveRecord::ConnectionNotEstablished) { observe("new@example.com") }
    end
    refute Bouncy.blocked?("new@example.com")
  end

  test "soft bounces and ambiguous complaints never create global policy" do
    observe(kind: "soft_bounce")
    observe(kind: "complaint", details: { "certainty" => "candidate" })
    observe(kind: "delivery")
    refute Bouncy.blocked?("ada@example.com")
    observe(kind: "complaint", details: { "certainty" => "confirmed" })
    assert_equal :complaint, Bouncy.status("ada@example.com").reason
  end

  test "unconfirmed events require grace and two complete absent observations" do
    observe(time: 2.hours.ago)
    Bouncy.sync!
    assert Bouncy.blocked?("ada@example.com")
    Bouncy.sync!
    refute Bouncy.blocked?("ada@example.com")
    observe(time: 3.hours.ago)
    refute Bouncy.blocked?("ada@example.com")
  end

  test "fresh provisional events survive absent provider lists" do
    observe
    2.times { Bouncy.sync! }
    assert Bouncy.blocked?("ada@example.com")
  end

  test "old and out of order evidence does not replace current policy" do
    observe(time: 91.days.ago)
    refute Bouncy.blocked?("ada@example.com")
    observe(kind: "complaint", details: { "certainty" => "confirmed" })
    observe(time: 1.day.ago)
    assert_equal :complaint, Bouncy.status("ada@example.com").reason
  end

  test "hooks run after commit and hook failure cannot undo accepted events" do
    seen = []
    Bouncy.configuration.after_block = lambda { |event|
      seen << [event.persisted?, Bouncy.blocked?(event.email)]
      raise "host callback failed"
    }
    assert_equal :accepted, observe
    assert_equal [[true, true]], seen
    assert Bouncy.blocked?("ada@example.com")
  end

  test "scope boundaries apply to all public queries and erasure" do
    observe
    Bouncy.configuration.scope = "ses:999999999999:us-east-1:account"
    refute Bouncy.blocked?("ada@example.com")
    assert_empty Bouncy.events.for("ada@example.com")
    Bouncy.forget!("ada@example.com")
    assert_equal 1, Bouncy::Suppression.count
    Bouncy.configuration.scope = "ses:123456789012:us-east-1:account"
    Bouncy.forget!("ada@example.com")
    assert_empty Bouncy.blocked
    assert_empty Bouncy.events
  end

  test "unknown status is not a delivery claim and known read outages are unavailable" do
    status = Bouncy.status("ada@example.com")
    assert_equal :no_known_block, status.knowledge
    assert status.stale?
    assert_nil status.observed_at
    Bouncy::Suppression.stub(:find_by, ->(*) { raise ActiveRecord::ConnectionNotEstablished }) do
      assert_equal :unavailable, Bouncy.status("ada@example.com").knowledge
      refute Bouncy.blocked?("ada@example.com")
    end
  end

  test "invalid inputs cannot mutate state" do
    ["", "missing", "@host", "a@", "a\nb@host", "ada@example.com\n", "#{'a' * 255}@host"].each do |email|
      assert_raises(Bouncy::InvalidAddress) { Bouncy.block!(email, note: "test") }
    end
    assert_raises(ArgumentError) { Bouncy.block!("ada@example.com", note: " ") }
    assert_raises(ArgumentError) { Bouncy.release!("ada@example.com", at: :other) }
    assert_raises(ArgumentError) { Bouncy.release!("ada@example.com") }
    assert_empty Bouncy::Suppression.all
  end

  test "temporary legacy holds expire consistently in predicates and scopes" do
    Bouncy::Store.change("ada@example.com") do |row|
      row.soft_blocked_until = 1.second.from_now
      row.summarize!
    end
    assert Bouncy.blocked?("ada@example.com")
    travel 2.seconds
    refute Bouncy.blocked?("ada@example.com")
    assert_empty Bouncy.blocked
  end
end
