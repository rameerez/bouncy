# frozen_string_literal: true

require "test_helper"

class SoftBounceMailer < ActionMailer::Base
  def notice(to:)
    mail(from: "sender@example.com", to: to, subject: "Subject", body: "Body")
  end
end

# Soft bounces are record-only until a host opts into escalation. Once it does, repeated soft
# bounces inside a rolling window hold the address locally, exactly like a host-owned threshold
# would, and recovery clears the history so the next single bounce does not re-hold it.
class SoftBounceTest < BouncyTest
  def setup
    super
    Bouncy.configuration.interception = :drop
    ActionMailer::Base.deliveries.clear
  end

  test "soft bounces only count by default and never block" do
    3.times { |index| observe(kind: "soft_bounce", id: "soft-#{index}") }

    row = Bouncy::Suppression.sole
    assert_equal 3, row.soft_bounce_count
    assert_nil row.soft_blocked_until
    assert_not row.blocked?
    assert_not Bouncy.blocked?("ada@example.com")
  end

  test "the configured threshold holds the address and the hook fires once" do
    blocks = []
    Bouncy.configuration.after_block = ->(event) { blocks << event.email }
    Bouncy.configuration.soft_bounce_threshold = 3
    Bouncy.configuration.soft_bounce_block_for = 30.days

    2.times { |index| observe(kind: "soft_bounce", id: "soft-#{index}") }
    assert_not Bouncy.blocked?("ada@example.com")
    assert_empty blocks

    observe(kind: "soft_bounce", id: "soft-3")

    row = Bouncy::Suppression.sole
    assert_equal 3, row.soft_bounce_count
    assert_in_delta 30.days.from_now.to_f, row.soft_blocked_until.to_f, 5
    assert_equal [:soft_bounces], row.reasons
    assert_equal "soft_bounces", row.reason
    assert Bouncy.blocked?("ada@example.com")
    assert_equal ["ada@example.com"], blocks
  end

  test "occurrences that age out of the window stop counting toward the threshold" do
    Bouncy.configuration.soft_bounce_threshold = 3
    Bouncy.configuration.soft_bounce_window = 30.days

    observe(kind: "soft_bounce", id: "old-1", time: 40.days.ago)
    observe(kind: "soft_bounce", id: "old-2", time: 35.days.ago)
    observe(kind: "soft_bounce", id: "recent", time: 1.day.ago)

    row = Bouncy::Suppression.sole
    assert_equal 1, row.soft_bounce_count
    assert_nil row.soft_blocked_until
    assert_not Bouncy.blocked?("ada@example.com")
  end

  test "a redelivered notification counts once" do
    Bouncy.configuration.soft_bounce_threshold = 3

    assert_equal :accepted, observe(kind: "soft_bounce", id: "same")
    assert_equal :duplicate, observe(kind: "soft_bounce", id: "same")
    assert_equal :duplicate, observe(kind: "soft_bounce", id: "same")

    assert_equal 1, Bouncy::Suppression.sole.soft_bounce_count
    assert_not Bouncy.blocked?("ada@example.com")
  end

  test "a soft hold is enforced without a fresh provider sync, and a tracker below it is not" do
    Bouncy.configuration.soft_bounce_threshold = 2
    2.times { |index| observe("held@example.com", kind: "soft_bounce", id: "held-#{index}") }
    observe("tracked@example.com", kind: "soft_bounce", id: "tracked-1")

    SoftBounceMailer.notice(to: ["held@example.com", "tracked@example.com"]).deliver_now

    delivered = ActionMailer::Base.deliveries.sole
    assert_equal ["tracked@example.com"], delivered.to
  end

  test "a hard bounce keeps its reason while soft evidence accumulates underneath" do
    Bouncy.configuration.soft_bounce_threshold = 2
    observe(kind: "hard_bounce", id: "hard-1")
    2.times { |index| observe(kind: "soft_bounce", id: "soft-#{index}") }

    row = Bouncy::Suppression.sole
    assert_equal %i[hard_bounce soft_bounces], row.reasons
    assert_equal "hard_bounce", row.reason
  end

  test "recovery clears the soft history so one later bounce does not re-hold the address" do
    Bouncy.configuration.soft_bounce_threshold = 2
    2.times { |index| observe(kind: "soft_bounce", id: "soft-#{index}") }
    assert Bouncy.blocked?("ada@example.com")

    Bouncy.release!("ada@example.com", at: :local, note: "Mailbox emptied", actor: "support:1")

    row = Bouncy::Suppression.sole
    assert_equal 0, row.soft_bounce_count
    assert_nil row.last_soft_bounce_at
    assert_not row.details.key?("soft_bounces")
    assert_not Bouncy.blocked?("ada@example.com")

    observe(kind: "soft_bounce", id: "after-release")
    assert_not Bouncy.blocked?("ada@example.com")
  end

  test "retained occurrences stay bounded" do
    Bouncy.configuration.soft_bounce_threshold = 2
    5.times { |index| observe(kind: "soft_bounce", id: "soft-#{index}") }

    assert_equal 2, Bouncy::Suppression.sole.details["soft_bounces"].size
  end

  test "an unusable threshold or window is refused at configuration time" do
    Bouncy.configuration.soft_bounce_threshold = 0
    assert_raises(Bouncy::ConfigurationError) { Bouncy.configuration.validate! }

    Bouncy.configuration.soft_bounce_threshold = "3"
    assert_raises(Bouncy::ConfigurationError) { Bouncy.configuration.validate! }

    Bouncy.configuration.soft_bounce_threshold = 3
    Bouncy.configuration.soft_bounce_window = 0.days
    assert_raises(Bouncy::ConfigurationError) { Bouncy.configuration.validate! }

    Bouncy.configuration.soft_bounce_window = 30.days
    Bouncy.configuration.soft_bounce_block_for = 0.days
    assert_raises(Bouncy::ConfigurationError) { Bouncy.configuration.validate! }
  end

  test "unreadable stored occurrences do not break ingestion" do
    Bouncy.configuration.soft_bounce_threshold = 2
    observe(kind: "soft_bounce", id: "soft-1")
    Bouncy::Suppression.sole.update!(details: { "soft_bounces" => ["not a time", nil] })

    assert_equal :accepted, observe(kind: "soft_bounce", id: "soft-2")
    assert_equal 1, Bouncy::Suppression.sole.soft_bounce_count
  end
end
