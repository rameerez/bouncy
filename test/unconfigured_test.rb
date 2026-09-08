# frozen_string_literal: true

require "test_helper"
require "support/signed_sns"

class UnconfiguredMailer < ActionMailer::Base
  def notice(to:)
    mail(from: "sender@example.com", to: to, subject: "Subject", body: "Body")
  end
end

class UnconfiguredContact < ActiveRecord::Base
  self.table_name = "contacts"
  bouncy :email
end

# A host can install the gem before its environment variables exist. Until config.scope is set
# Bouncy is inactive: mail goes out untouched, every address reads as unrestricted, relations
# are empty, and a warning is logged once. Explicit operations still fail loudly.
class UnconfiguredTest < BouncyTest
  include SignedSns

  def setup
    super
    Bouncy.block!("ada@example.com", note: "Hold written while configured")
    Bouncy.configuration.interception = :drop
    Bouncy.configuration.scope = nil
    ActionMailer::Base.deliveries.clear
  end

  test "mail is delivered untouched and a warning is logged once" do
    log = StringIO.new
    previous_logger = Rails.logger
    Rails.logger = Logger.new(log)
    notifications = []
    subscriber = ActiveSupport::Notifications.subscribe("unconfigured.bouncy") { |*args| notifications << args.last[:operation] }
    events_before = Bouncy::Event.count

    message = UnconfiguredMailer.notice(to: "ada@example.com").deliver_now
    UnconfiguredMailer.notice(to: "ada@example.com").deliver_now
    assert_equal ["ada@example.com"], message.to
    assert_equal ["ada@example.com"], message.smtp_envelope_to
    assert_equal 2, ActionMailer::Base.deliveries.size
    assert_equal events_before, Bouncy::Event.count
    assert_equal %w[interception interception], notifications
    assert_equal 1, log.string.scan("[bouncy] config.scope is not set").size
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
    Rails.logger = previous_logger
  end

  test "status and predicates report unconfigured without raising" do
    status = Bouncy.status("ada@example.com")
    assert_equal :unconfigured, status.knowledge
    refute status.blocked?
    refute status.release_supported?
    refute status.provider_listed?
    refute status.policy_unverified?
    assert status.stale?
    previous_logger = Rails.logger
    Rails.logger = nil
    assert_equal :unconfigured, Bouncy.status("ada@example.com").knowledge, "a missing logger is tolerated"
    Rails.logger = previous_logger
    refute Bouncy.blocked?("ada@example.com")
    assert_empty Bouncy.blocked
    assert_empty Bouncy.events
    assert_nil Bouncy.last_sync
    contact = UnconfiguredContact.create!(email: "ada@example.com")
    refute contact.email_blocked?
    assert_empty UnconfiguredContact.email_blocked.to_a
    assert_equal [contact], UnconfiguredContact.email_unblocked.to_a
  end

  test "explicit operations and the receiver refuse to run" do
    assert_raises(Bouncy::ConfigurationError) { Bouncy.sync! }
    assert_raises(Bouncy::ConfigurationError) { Bouncy.block!("ben@example.com", note: "x") }
    assert_raises(Bouncy::ConfigurationError) { Bouncy.release!("ada@example.com", note: "x") }
    assert_raises(Bouncy::ConfigurationError) { Bouncy.forget!("ada@example.com") }
    Bouncy.configuration.adapter = nil
    status, = Bouncy::Webhook.new.call("REQUEST_METHOD" => "POST", "rack.input" => StringIO.new(signed_envelope))
    assert_equal 503, status
    Bouncy.configuration.scope = "ses:123456789012:us-east-1:account"
    assert Bouncy.blocked?("ada@example.com"), "state written earlier is intact once configured again"
  end
end
