# frozen_string_literal: true

require "test_helper"
require "support/signed_sns"

# config.on_notification: every SES notification reaches the app synchronously, after Bouncy
# committed what it records from it and before the receiver answers SNS.
class NotificationTest < BouncyTest
  include SignedSns

  def setup
    super
    Bouncy.configuration.adapter = nil
    Bouncy.configuration.ses.region = "us-east-1"
    Bouncy.configuration.ses.topic_arns = [TOPIC]
    stub_request(:get, CERT_URL).to_return(body: CERT.to_pem)
  end

  def ses_event(type, message_id: "ses-message-1", tags: nil, **sections)
    mail = { "messageId" => message_id, "timestamp" => "2026-10-24T10:00:00.000Z", "destination" => ["Ana <ana@example.com>", "bea@example.com"] }
    mail["tags"] = tags.transform_values { |value| [value] } if tags
    JSON.generate({ "eventType" => type, "mail" => mail }.merge(sections.transform_keys(&:to_s)))
  end

  def post(message, **fields)
    Bouncy::Webhook.new.call("REQUEST_METHOD" => "POST", "rack.input" => StringIO.new(signed_envelope({ "Message" => message }.merge(fields)))).first
  end

  def received
    notifications = []
    Bouncy.configuration.on_notification = ->(notification) { notifications << notification }
    yield
    notifications
  end

  test "send and delivery events change nothing here and reach the app with their facts" do
    notifications = received do
      assert_equal 200, post(ses_event("Send", tags: { "order" => "42" }, send: {}))
      assert_equal 200, post(ses_event("Delivery", delivery: { "timestamp" => "2026-10-24T10:00:05.000Z", "recipients" => ["ana@example.com"] }),
                             "MessageId" => "sns-2")
    end

    assert_empty Bouncy.blocked
    send, delivery = notifications
    assert_equal %w[Send Delivery], notifications.map(&:type)
    assert_equal ["ses-message-1", { "order" => ["42"] }], [send.message_id, send.tags]
    assert_equal Time.iso8601("2026-10-24T10:00:00Z"), send.occurred_at, "a Send event takes the time of the mail"
    assert_equal ["Ana <ana@example.com>", "bea@example.com"], send.recipients
    assert_equal Time.iso8601("2026-10-24T10:00:05Z"), delivery.occurred_at
    assert_equal ["ana@example.com"], delivery.recipients
    assert_equal({}, delivery.tags)
    assert_equal "Delivery", delivery.raw["eventType"]
  end

  test "a bounce reaches the app after its block committed, outside any transaction" do
    seen = nil
    Bouncy.configuration.on_notification = lambda do |notification|
      seen = [notification.type, notification.recipients, Bouncy.blocked?("ada@example.com"), Bouncy::Record.connection.transaction_open?]
    end

    assert_equal 200, post(JSON.generate("eventType" => "Bounce", "mail" => { "messageId" => "m-1" }, "bounce" => {
                                           "bounceType" => "Permanent", "bounceSubType" => "General", "feedbackId" => "f-1",
                                           "timestamp" => "2026-10-24T10:01:00.000Z", "bouncedRecipients" => [{ "emailAddress" => "Ada@Example.com" }]
                                         }))

    assert_equal ["Bounce", ["Ada@Example.com"], true, false], seen
  end

  test "a hook that raises answers 503, so SNS delivers again; the block stays, and the repeat deduplicates" do
    calls = 0
    Bouncy.configuration.on_notification = lambda do |_notification|
      calls += 1
      raise "the app's own handling failed" if calls == 1
    end
    errors = []
    subscriber = ActiveSupport::Notifications.subscribe("hook_error.bouncy") { |*args| errors << args.last }

    assert_equal 503, Bouncy::Webhook.new.call("REQUEST_METHOD" => "POST", "rack.input" => StringIO.new(signed_envelope)).first
    assert Bouncy.blocked?("ada@example.com")
    assert_equal 200, Bouncy::Webhook.new.call("REQUEST_METHOD" => "POST", "rack.input" => StringIO.new(signed_envelope)).first

    assert_equal 2, calls
    assert_equal 2, Bouncy.events.count, "one event per recipient, not one per delivery"
    assert_equal [{ hook: :on_notification, error_class: "RuntimeError" }], errors
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  test "refused messages and subscription confirmations do not reach the hook" do
    Bouncy.configuration.ses.sns_client = Aws::SNS::Client.new(region: "us-east-1", stub_responses: true)
    notifications = received do
      assert_equal 401, post(ses_event("Delivery"), "TopicArn" => "arn:aws:sns:us-east-1:999999999999:feedback")
      assert_equal 400, post("{")
      assert_equal 200, Bouncy::Webhook.new.call("REQUEST_METHOD" => "POST", "rack.input" => StringIO.new(
        signed_envelope("Type" => "SubscriptionConfirmation", "Token" => "token", "SubscribeURL" => "https://sns.us-east-1.amazonaws.com/")
      )).first
    end
    assert_empty notifications
  end

  test "an injected adapter without notifications is still answered" do
    adapter = Object.new
    def adapter.authenticate(raw_body:, **) = JSON.parse(raw_body)
    def adapter.control(_envelope) = false # rubocop:disable Naming/PredicateMethod -- the adapter contract's name
    def adapter.parse(_envelope) = []
    Bouncy.configuration.adapter = adapter
    Bouncy.configuration.on_notification = ->(_notification) { flunk "no notification to give" }
    assert_equal 200, Bouncy::Webhook.new.call("REQUEST_METHOD" => "POST", "rack.input" => StringIO.new(JSON.generate("Type" => "Notification"))).first
  end

  test "readers follow the SES section of each event type" do
    complained = { "timestamp" => "2026-10-24T11:00:00Z", "complainedRecipients" => [{ "emailAddress" => "bea@example.com" }] }
    complaint = Bouncy::Notification.new(JSON.parse(ses_event("Complaint", complaint: complained)))
    assert_equal [["bea@example.com"], Time.iso8601("2026-10-24T11:00:00Z")], [complaint.recipients, complaint.occurred_at]

    delayed = { "delayedRecipients" => [{ "emailAddress" => "ana@example.com" }] }
    delay = Bouncy::Notification.new(JSON.parse(ses_event("DeliveryDelay", deliveryDelay: delayed)))
    assert_equal ["ana@example.com"], delay.recipients
    failure = Bouncy::Notification.new(JSON.parse(ses_event("Rendering Failure", failure: { "errorMessage" => "x" })))
    assert_equal ["Ana <ana@example.com>", "bea@example.com"], failure.recipients

    identity = Bouncy::Notification.new({ "notificationType" => "Bounce", "bounce" => { "bouncedRecipients" => [{ "emailAddress" => "ana@example.com" }] } },
                                        sns_timestamp: "2026-10-24T12:00:00Z")
    assert_equal ["Bounce", ["ana@example.com"], nil, {}], [identity.type, identity.recipients, identity.message_id, identity.tags]
    assert_equal Time.iso8601("2026-10-24T12:00:00Z"), identity.occurred_at, "the time SNS published it comes last"

    broken = Bouncy::Notification.new({ "eventType" => "Open", "open" => { "timestamp" => "not a time" }, "mail" => "not an object" })
    assert_equal [[], {}, nil], [broken.recipients, broken.tags, broken.occurred_at]
    odd = Bouncy::Notification.new({ "eventType" => "Delivery", "delivery" => { "recipients" => ["ana@example.com", 42, nil, { "x" => 1 }] } })
    assert_equal ["ana@example.com"], odd.recipients
  end
end
