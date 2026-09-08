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

class SyncIdempotencyTest < BouncyTest
  test "changed provider timestamps persist without restriction events or hooks" do
    @provider.entries = [entry(time: 2.days.ago)]
    Bouncy.sync!
    version = Bouncy::Suppression.sole.lock_version
    events = Bouncy.events.where.not(kind: "sync").count
    hooks = []
    Bouncy.configuration.after_event = ->(event) { hooks << event.kind }
    timestamp = 1.day.ago.change(usec: 0)
    @provider.entries = [entry(time: timestamp)]
    Bouncy.sync!
    assert_equal timestamp, Bouncy.status("ada@example.com").provider_updated_at
    assert_operator Bouncy::Suppression.sole.lock_version, :>, version
    assert_equal events, Bouncy.events.where.not(kind: "sync").count
    assert_equal ["sync"], hooks
    version = Bouncy::Suppression.sole.lock_version
    Bouncy.sync!
    assert_equal version, Bouncy::Suppression.sole.lock_version
  end

  test "partial snapshots refresh evidence while preserving missing variants and newer observations" do
    @provider.entries = [entry(time: 3.days.ago), entry("ADA@example.com", reason: :complaint)]
    Bouncy.sync!
    @provider.complete = false
    timestamp = 1.day.ago.change(usec: 0)
    @provider.entries = [entry(time: timestamp)]
    Bouncy.sync!
    row = Bouncy::Suppression.sole
    assert_equal 2, row.provider_entries.size
    assert_equal timestamp.iso8601(6), row.provider_entries.find { |item| item["email"] == "Ada@Example.com" }["provider_updated_at"]
    assert_equal :complaint, row.reason.to_sym
    @provider.entries = [entry(time: 2.days.ago)]
    Bouncy.sync!
    assert_equal row.provider_entries, row.reload.provider_entries
    assert_empty Bouncy.events.where(kind: "sync_updated")
  end

  test "new provider evidence during recovery prevents clearing local state" do
    @provider.entries = [entry(time: 2.days.ago)]
    Bouncy.sync!
    @provider.on_release = lambda {
      @provider.entries = [entry(time: Time.current)]
      Bouncy.sync!
    }
    assert_raises(Bouncy::ReleaseConflict) { Bouncy.release!("ada@example.com", note: "Recovery") }
    assert Bouncy.blocked?("ada@example.com")
    assert_equal "release_failed", Bouncy.events.last.kind
  end

  test "repeated identical snapshots write no events, fire no hooks and bump no versions" do
    @provider.entries = [entry, entry("Bob@Example.com", reason: :complaint)]
    Bouncy.sync!
    assert_equal 2, Bouncy.events.where(kind: "sync_added").count
    events = Bouncy.events.count
    versions = Bouncy::Suppression.order(:email).pluck(:email, :lock_version)
    checked = Bouncy::Suppression.find_by!(email: "ada@example.com").provider_checked_at
    hooks = 0
    Bouncy.configuration.after_event = ->(_event) { hooks += 1 }
    travel 10.minutes
    @provider.entries.reverse! # Provider pagination order is not a change in evidence.
    3.times { Bouncy.sync! }
    assert_equal events + 3, Bouncy.events.count, "only the three sync summaries were recorded"
    assert_equal 3, hooks
    assert_equal versions, Bouncy::Suppression.order(:email).pluck(:email, :lock_version)
    assert_operator Bouncy::Suppression.find_by!(email: "ada@example.com").provider_checked_at, :>, checked
    assert_equal 2, Bouncy.last_sync.details["unchanged"]
    assert_equal 0, Bouncy.last_sync.details["added"]
    assert Bouncy.blocked?("ada@example.com")
    assert Bouncy.blocked?("bob@example.com")
  end

  test "a changed reason is recorded once as an update" do
    @provider.entries = [entry]
    Bouncy.sync!
    @provider.entries = [entry, entry("ADA@example.com", reason: :complaint)]
    Bouncy.sync!
    assert_equal 1, Bouncy.events.where(kind: "sync_updated").count
    assert_equal :complaint, Bouncy.status("ada@example.com").reason
    Bouncy.sync!
    assert_equal 1, Bouncy.events.where(kind: "sync_updated").count
  end

  test "rows without provider evidence cost no provider lookups and no events" do
    Bouncy.block!("carol@example.com", note: "Support hold")
    @provider.entries = [entry]
    Bouncy.sync!
    Bouncy.release!("ada@example.com", note: "Recovered")
    lookups = @provider.lookups.size
    events = Bouncy.events.count
    2.times { Bouncy.sync! }
    assert_equal lookups, @provider.lookups.size
    assert_equal events + 2, Bouncy.events.count
    assert_equal [:manual], Bouncy.status("carol@example.com").reasons
    assert_equal 0, Bouncy.events.where(kind: "sync_released").count
  end

  test "an absence that changes nothing yet is not reported as a release" do
    observe(time: 2.hours.ago)
    Bouncy.sync!
    assert_equal 0, Bouncy.events.where(kind: "sync_released").count
    assert Bouncy.blocked?("ada@example.com")
    Bouncy.sync!
    assert_equal 1, Bouncy.events.where(kind: "sync_released").count
    assert Bouncy.events.where(kind: "sync_released").sole.details["became_unblocked"]
    refute Bouncy.blocked?("ada@example.com")
  end

  test "status describes a listed and enforced address and other providers cannot release" do
    @provider.entries = [entry]
    Bouncy.sync!
    status = Bouncy.status("ada@example.com")
    assert status.provider_listed?
    refute status.policy_unverified?
    assert status.release_supported?
    Bouncy.configuration.provider = :other
    refute Bouncy.status("ada@example.com").release_supported?
    refute Bouncy.status("nobody@example.com").provider_listed?
  end

  test "observation mode reports why nothing is enforced" do
    @provider.entries = [entry]
    @provider.policy_verified = false
    @provider.define_singleton_method(:snapshot) do
      Bouncy::Providers::Snapshot.new(entries: entries, scope: Bouncy.scope, complete: true, policy_verified: false,
                                      policy_reason: "listed sending paths are incomplete", started_at: Time.current, finished_at: Time.current)
    end
    Bouncy.sync!
    assert_equal "listed sending paths are incomplete", Bouncy.last_sync.details["policy_reason"]
    status = Bouncy.status("ada@example.com")
    assert status.provider_listed?
    assert status.policy_unverified?
    assert_equal "listed sending paths are incomplete", status.policy_reason
    refute status.blocked?
    assert_equal :observed, status.knowledge
  end

  test "status follows policy verification loss and recovery without erasing restriction history" do
    @provider.entries = [entry]
    Bouncy.sync!
    evidence = Bouncy::Suppression.sole.provider_entries
    blocked_at = Bouncy::Suppression.sole.provider_blocked_at
    refute Bouncy.status("ada@example.com").policy_unverified?
    assert_nil Bouncy.status("ada@example.com").policy_reason
    travel 1.second
    @provider.policy_verified = false
    @provider.policy_reason = "listed sending paths are incomplete"
    @provider.entries = [] # Policy applies even to rows absent from an unverified snapshot.
    Bouncy.sync!
    status = Bouncy.status("ada@example.com")
    assert status.policy_unverified?
    assert_equal @provider.policy_reason, status.policy_reason
    assert status.blocked?, "historical restriction evidence remains queryable"
    assert_equal evidence, Bouncy::Suppression.sole.provider_entries
    assert_equal blocked_at, Bouncy::Suppression.sole.provider_blocked_at
    Bouncy.configuration.interception = :drop
    message = Mail.new(to: "ada@example.com", from: "sender@example.com", body: "test")
    Bouncy::Interceptor.delivering_email(message)
    assert message.perform_deliveries
    assert_equal ["ada@example.com"], message.smtp_envelope_to
    travel 1.second
    @provider.entries = [entry]
    @provider.policy_verified = true
    @provider.policy_reason = nil
    Bouncy.sync!
    refute Bouncy.status("ada@example.com").policy_unverified?
    assert_nil Bouncy.status("ada@example.com").policy_reason
    Bouncy::Interceptor.delivering_email(message)
    refute message.perform_deliveries
  end

  test "status treats failed or missing policy checks as unknown and respects scope" do
    @provider.entries = [entry]
    Bouncy.sync!
    original_scope = Bouncy.scope
    Bouncy.configuration.scope = "ses:999999999999:us-east-1:account"
    @provider.policy_verified = false
    Bouncy.sync!
    Bouncy.configuration.scope = original_scope
    refute Bouncy.status("ada@example.com").policy_unverified?
    travel 1.second
    @provider.stub(:snapshot, -> { raise Bouncy::ProviderError, "offline" }) do
      assert_raises(Bouncy::ProviderError) { Bouncy.sync! }
    end
    assert Bouncy.status("ada@example.com").policy_unverified?
    assert_equal "Sending policy could not be verified", Bouncy.status("ada@example.com").policy_reason
    Bouncy.events.delete_all
    assert Bouncy.status("ada@example.com").policy_unverified?
    assert_equal "Sending policy has not been checked", Bouncy.status("ada@example.com").policy_reason
    assert_nil Bouncy.status("nobody@example.com").policy_reason
  end

  test "policy status handles read outages without concealing SQL bugs" do
    @provider.entries = [entry]
    Bouncy.sync!
    status = Bouncy.status("ada@example.com")
    Bouncy::Event.stub(:where, ->(*) { raise ActiveRecord::ConnectionNotEstablished }) do
      assert status.policy_unverified?
      assert_match(/database could not be reached/, status.policy_reason)
    end
    status = Bouncy.status("ada@example.com")
    Bouncy::Event.stub(:where, ->(*) { raise ActiveRecord::StatementInvalid, "bad SQL" }) do
      assert_raises(ActiveRecord::StatementInvalid) { status.policy_unverified? }
    end
  end
end
