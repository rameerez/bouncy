# frozen_string_literal: true

require "test_helper"
require "support/signed_sns"

class WebhookBlockingMailer < ActionMailer::Base
  def notice(to)
    mail(from: "sender@example.com", to: to, subject: "Notice", body: "Hello")
  end
end

# config.webhook_blocking: which SES notifications block an address. :strict, the default
# without a sync, blocks every Permanent bounce and every recipient a complaint names. :cautious,
# the default while a sync runs, blocks General and NoEmail bounces and complaints that name one
# recipient, and leaves the rest to the sync.
class WebhookBlockingTest < BouncyTest
  include SignedSns

  PERMANENT_SUBTYPES = ["General", "NoEmail", "Suppressed", "OnAccountSuppressionList", "OnTenantSuppressionList",
                        "UnsubscribedRecipient", "EmailValidationSuppressed", "SubtypeFromTheFuture", nil].freeze

  # The shape SES publishes when it did not send to an address on the account-level list.
  def account_list_bounce(address, feedback: "feedback-account-list")
    {
      "eventType" => "Bounce",
      "bounce" => {
        "feedbackId" => feedback, "bounceType" => "Permanent", "bounceSubType" => "OnAccountSuppressionList",
        "bouncedRecipients" => [{
          "emailAddress" => address, "action" => "failed", "status" => "5.1.1",
          "diagnosticCode" => "Amazon SES did not send the message to this address because it is on the suppression list for your account."
        }],
        "timestamp" => Time.current.iso8601(3), "reportingMTA" => "dns; amazonses.com"
      },
      "mail" => {
        "timestamp" => Time.current.iso8601(3), "source" => "sender@example.com", "sendingAccountId" => "123456789012",
        "messageId" => "ses-message-1", "destination" => [address]
      }
    }
  end

  def bounce(address, type, subtype, feedback:)
    data = { "bounceType" => type, "feedbackId" => feedback, "timestamp" => Time.current.iso8601,
             "bouncedRecipients" => [{ "emailAddress" => address }] }
    data["bounceSubType"] = subtype if subtype
    { "notificationType" => "Bounce", "bounce" => data, "mail" => { "destination" => [address] } }
  end

  def complaint(recipients, feedback:, **fields)
    data = { "feedbackId" => feedback, "timestamp" => Time.current.iso8601,
             "complainedRecipients" => recipients.map { |address| { "emailAddress" => address } } }.merge(fields.transform_keys(&:to_s))
    { "notificationType" => "Complaint", "complaint" => data, "mail" => { "destination" => recipients } }
  end

  def ingest(payload)
    envelope = { "Message" => JSON.generate(payload), "MessageId" => SecureRandom.uuid, "Timestamp" => Time.current.iso8601 }
    Bouncy::Providers::SesParser.new(Bouncy.configuration).call(envelope).each { |observation| Bouncy::Ingestor.new.call(observation) }
  end

  test "strict is the default without a fresh-sync requirement, cautious otherwise, and an explicit choice wins" do
    configuration = Bouncy.configuration
    assert_equal :cautious, configuration.webhook_blocking
    configuration.require_fresh_sync = false
    assert_equal :strict, configuration.webhook_blocking
    configuration.webhook_blocking = :cautious
    assert_equal :cautious, configuration.webhook_blocking
    configuration.require_fresh_sync = true
    configuration.webhook_blocking = :strict
    assert_equal :strict, configuration.webhook_blocking
    configuration.webhook_blocking = :everything
    assert_raises(Bouncy::ConfigurationError) { configuration.validate! }
  end

  test "strict: every Permanent bounce blocks, whatever its subtype" do
    Bouncy.configuration.webhook_blocking = :strict
    PERMANENT_SUBTYPES.each_with_index do |subtype, index|
      address = "permanent-#{index}@example.com"
      ingest(bounce(address, "Permanent", subtype, feedback: "permanent-#{index}"))
      assert Bouncy.blocked?(address), subtype.inspect
      assert_equal :hard_bounce, Bouncy.status(address).reason, subtype.inspect
    end
  end

  test "cautious: only General and NoEmail bounces block; the sync covers the rest" do
    Bouncy.configuration.webhook_blocking = :cautious
    PERMANENT_SUBTYPES.each_with_index do |subtype, index|
      address = "permanent-#{index}@example.com"
      ingest(bounce(address, "Permanent", subtype, feedback: "cautious-#{index}"))
      assert_equal %w[General NoEmail].include?(subtype), Bouncy.blocked?(address), subtype.inspect
    end
  end

  test "strict: Transient and Undetermined bounces are recorded only" do
    Bouncy.configuration.webhook_blocking = :strict
    [%w[Transient General], %w[Transient MailboxFull], %w[Transient ContentRejected], %w[Undetermined Undetermined]].each_with_index do |(type, subtype), index|
      address = "soft-#{index}@example.com"
      ingest(bounce(address, type, subtype, feedback: "soft-#{index}"))
      refute Bouncy.blocked?(address), "#{type}/#{subtype}"
      assert_equal "soft_bounce", Bouncy.events.for(address).sole.kind
    end
  end

  test "strict: every recipient a complaint names blocks, and a not-spam report blocks nothing" do
    Bouncy.configuration.webhook_blocking = :strict
    ingest(complaint(%w[ana@example.com bea@example.com], feedback: "several", complaintFeedbackType: "abuse"))
    ingest(complaint(%w[cleo@example.com], feedback: "listed", complaintSubType: "OnAccountSuppressionList"))
    ingest(complaint(%w[dan@example.com], feedback: "no-report"))
    ingest(complaint(%w[eve@example.com], feedback: "not-spam", complaintFeedbackType: "not-spam"))

    %w[ana@example.com bea@example.com cleo@example.com dan@example.com].each do |address|
      assert Bouncy.blocked?(address), address
      assert_equal :complaint, Bouncy.status(address).reason
    end
    assert_equal(%w[candidate candidate], Bouncy.events.where(email: %w[ana@example.com bea@example.com]).map { |event| event.details["certainty"] })
    refute Bouncy.blocked?("eve@example.com")
  end

  test "cautious: a complaint that names several recipients leaves them as candidates" do
    Bouncy.configuration.webhook_blocking = :cautious
    ingest(complaint(%w[ana@example.com bea@example.com], feedback: "several"))
    ingest(complaint(%w[cleo@example.com], feedback: "one"))
    ingest(complaint(%w[dan@example.com], feedback: "listed", complaintSubType: "OnAccountSuppressionList"))
    refute Bouncy.blocked?("ana@example.com")
    refute Bouncy.blocked?("bea@example.com")
    assert Bouncy.blocked?("cleo@example.com")
    refute Bouncy.blocked?("dan@example.com")
  end

  test "webhook-only mode blocks an account-list bounce from the real payload and drops the next mail" do
    Bouncy.configuration.adapter = nil
    Bouncy.configuration.ses.region = "us-east-1"
    Bouncy.configuration.ses.topic_arns = [TOPIC]
    Bouncy.configuration.require_fresh_sync = false
    Bouncy.configuration.interception = :drop
    stub_request(:get, CERT_URL).to_return(body: CERT.to_pem)
    ActionMailer::Base.deliveries.clear

    body = signed_envelope("Message" => JSON.generate(account_list_bounce("Ana@Example.com")))
    assert_equal 200, Bouncy::Webhook.new.call("REQUEST_METHOD" => "POST", "rack.input" => StringIO.new(body)).first

    assert Bouncy.blocked?("ana@example.com")
    event = Bouncy.events.where(kind: "hard_bounce").sole
    assert_equal %w[OnAccountSuppressionList OnAccountSuppressionList], [event.provider_reason, event.details["classification"]]
    WebhookBlockingMailer.notice("ana@example.com").deliver_now
    assert_empty ActionMailer::Base.deliveries
    assert_nil Bouncy.last_sync, "no sync read the account list"
  end
end
