# frozen_string_literal: true

require "test_helper"

class SesParserTest < BouncyTest
  test "bounce classes are mapped by policy meaning" do
    cases = [
      %w[Permanent General hard_bounce], %w[Permanent NoEmail hard_bounce],
      %w[Permanent OnAccountSuppressionList provider_suppressed],
      %w[Permanent Suppressed unknown], %w[Permanent OnTenantSuppressionList unknown],
      %w[Permanent EmailValidationSuppressed unknown], %w[Permanent UnsubscribedRecipient unsubscribe],
      %w[Transient MailboxFull soft_bounce], %w[Transient MessageTooLarge soft_bounce],
      %w[Transient ContentRejected soft_bounce], %w[Transient AttachmentRejected soft_bounce],
      %w[Undetermined General soft_bounce], %w[Permanent FutureSubtype unknown]
    ]
    cases.each do |type, subtype, kind|
      event = parse("eventType" => "Bounce", "bounce" => { "bounceType" => type, "bounceSubType" => subtype,
                                                           "bouncedRecipients" => [{ "emailAddress" => "ADA@Example.com", "status" => "5.1.1",
                                                                                     "diagnosticCode" => "x" * 2000 }] }).first
      assert_equal kind, event.kind, subtype
      assert_equal "ada@example.com", event.email
      assert_equal "ADA@Example.com", event.details["exact_email"]
      assert_operator event.diagnostic.size, :<=, 1000
    end
  end

  test "complaint candidates are not certified as the individual reporter" do
    events = parse("notificationType" => "Complaint", "complaint" => { "feedbackId" => "feedback",
                                                                       "complainedRecipients" => [{ "emailAddress" => "a@example.com" },
                                                                                                  { "emailAddress" => "b@example.com" }] })
    assert_equal 2, events.size
    assert(events.all? { |event| event.kind == "complaint" && event.details["certainty"] == "candidate" })
    single = parse("notificationType" => "Complaint", "complaint" => { "complainedRecipients" => [{ "emailAddress" => "a@example.com" }] }).first
    assert_equal "confirmed", single.details["certainty"]
    bounce = parse("eventType" => "Bounce", "bounce" => { "bounceType" => "Permanent", "bouncedRecipients" => ["a@example.com"] }).first
    refute bounce.details.key?("certainty")
    event = parse("eventType" => "Complaint", "complaint" => { "complaintFeedbackType" => "not-spam",
                                                               "complainedRecipients" => ["a@example.com"] }).first
    assert_equal "ignored", event.kind
  end

  test "delivery is opt in and uses actual recipients rather than mail destinations" do
    payload = { "eventType" => "Delivery", "delivery" => { "recipients" => ["a@example.com"], "timestamp" => Time.current.iso8601 },
                "mail" => { "destination" => ["wrong@example.com"], "messageId" => "mail-id" } }
    assert_equal "ignored", parse(payload).first.kind
    Bouncy.configuration.record_deliveries = true
    event = parse(payload).first
    assert_equal "delivery", event.kind
    assert_equal "a@example.com", event.email
    refute event.details["timestamp_fallback"]
    assert_equal "mail-id", event.message_id
  end

  test "suppression complaint subtypes are diagnostics rather than new complaints" do
    { "OnAccountSuppressionList" => "provider_suppressed", "OnTenantSuppressionList" => "unknown", "FutureSubtype" => "unknown" }.each do |subtype, kind|
      %w[notificationType eventType].each do |dialect|
        event = parse(dialect => "Complaint", "complaint" => {
                        "complaintSubType" => subtype, "complaintFeedbackType" => "abuse",
                        "feedbackId" => "#{dialect}-#{subtype}", "complainedRecipients" => [{ "emailAddress" => "ada@example.com" }]
                      }).sole
        assert_equal kind, event.kind
        assert_equal subtype, event.provider_reason
        refute event.details.key?("certainty")
        Bouncy::Ingestor.new.call(event)
        refute Bouncy.blocked?("ada@example.com")
      end
    end
    assert_empty Bouncy.events.where(kind: "complaint")
    assert_equal 6, Bouncy.events.count
  end

  test "delays and message errors are harmless records" do
    event = parse("eventType" => "DeliveryDelay", "deliveryDelay" => { "delayedRecipients" => [{ "emailAddress" => "a@example.com" }] }).first
    assert_equal "delay", event.kind
    { "Reject" => "reject", "RenderingFailure" => "rendering_failure", "Send" => "ignored", "Open" => "ignored", "Click" => "ignored" }.each do |type, kind|
      assert_equal kind, parse("eventType" => type).first.kind
    end
  end

  test "malformed recipients produce recipientless diagnostics" do
    event = parse("eventType" => "Bounce", "bounce" => { "bouncedRecipients" => ["bad address"] }).first
    assert_nil event.email
    assert_equal "ignored", event.kind
    assert event.details["invalid_recipient"]
  end

  test "malformed structure and unbounded recipient lists are rejected" do
    [[], { "eventType" => "Bounce", "bounce" => [] }, { "mail" => [] },
     { "eventType" => "Bounce", "bounce" => { "bouncedRecipients" => "bad" } },
     { "eventType" => "Bounce", "bounce" => { "bouncedRecipients" => Array.new(1001, "a@example.com") } },
     { "eventType" => "Bounce", "bounce" => { "timestamp" => "yesterday" } }].each do |payload|
      assert_raises(Bouncy::MalformedMessage) { parse(payload) }
    end
    assert_raises(Bouncy::MalformedMessage) { Bouncy::Providers::SesParser.new(Bouncy.configuration).call("Message" => "{") }
  end

  private

  def parse(payload)
    Bouncy::Providers::SesParser.new(Bouncy.configuration).call("Message" => JSON.generate(payload), "MessageId" => "sns-id",
                                                                "Timestamp" => Time.current.iso8601)
  end
end
