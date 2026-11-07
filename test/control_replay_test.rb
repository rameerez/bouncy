# frozen_string_literal: true

require "test_helper"
require "support/signed_sns"

class ControlReplayTest < BouncyTest
  include SignedSns

  URL = "https://sns.us-east-1.amazonaws.com/?Action=ConfirmSubscription&TopicArn=#{TOPIC}&Token=fictional".freeze

  def setup
    super
    Bouncy.configuration.adapter = nil
    Bouncy.configuration.ses.region = "us-east-1"
    Bouncy.configuration.ses.topic_arns = [TOPIC]
    Bouncy.configuration.ses.sns_client = Aws::SNS::Client.new(region: "us-east-1", stub_responses: true)
    stub_request(:get, CERT_URL).to_return(body: CERT.to_pem)
  end

  test "a confirmed SubscriptionConfirmation replayed later is answered 200 without confirming again" do
    body = confirmation
    assert_equal 200, post(body)
    travel 1.day
    assert_equal 200, post(body)
    assert_equal 1, Bouncy.configuration.ses.sns_client.api_requests.size
    assert_equal 1, Bouncy.events.where(kind: "subscription_confirmed").count
    assert_equal 200, post(confirmation("MessageId" => "confirmation-2")), "a new confirmation from SNS still acts"
    assert_equal 2, Bouncy.configuration.ses.sns_client.api_requests.size
  end

  test "with subscribe_url a replay never visits SNS again, while a retry after a failure does" do
    Bouncy.configuration.ses.subscription_confirmation = :subscribe_url
    visit = stub_request(:get, URL).to_return({ status: 500 }, { status: 200 })
    body = confirmation("SubscribeURL" => URL)
    assert_equal 503, post(body)
    assert_equal 200, post(body), "the SNS retry of a failed confirmation still confirms"
    assert_equal 200, post(body)
    assert_requested visit, times: 2
    assert_equal 1, Bouncy.events.where(kind: "subscription_confirmed").count
  end

  test "a confirmation older than the token's three days, or from the future, is refused without acting" do
    travel_to Time.utc(2026, 11, 7, 12)
    old = confirmation("Timestamp" => (Time.current - 4.days).iso8601)
    retried = confirmation("MessageId" => "late-retry", "Timestamp" => (Time.current - 2.days).iso8601)
    future = confirmation("MessageId" => "future", "Timestamp" => (Time.current + 10.minutes).iso8601)
    output = logged do
      assert_equal 400, post(old)
      assert_equal 400, post(future)
    end
    assert_match(/control message is older than 259200s/, output)
    assert_match(/control message is dated in the future/, output)
    assert_empty Bouncy.configuration.ses.sns_client.api_requests
    assert_equal 200, post(retried), "within the token's lifetime a late retry still confirms"
    assert_equal 1, Bouncy.configuration.ses.sns_client.api_requests.size
  end

  test "a retention shorter than three days shortens the age limit, so the dedupe record outlives it" do
    Bouncy.configuration.maximum_event_age = 1.day
    Bouncy.configuration.retention = 1.day
    assert_equal 400, post(confirmation("Timestamp" => 2.days.ago.iso8601))
    assert_equal 200, post(confirmation("MessageId" => "recent", "Timestamp" => 12.hours.ago.iso8601))
  end

  test "an UnsubscribeConfirmation is recorded once however often it is delivered" do
    body = signed_envelope("Type" => "UnsubscribeConfirmation", "MessageId" => "unsubscribe-1", "Token" => "fictional",
                           "SubscribeURL" => URL, "Message" => "You have chosen to deactivate subscription")
    3.times { assert_equal 200, post(body) }
    assert_equal 1, Bouncy.events.where(kind: "subscription_unsubscribed").count
  end

  test "two racing deliveries of one confirmation record it once" do
    adapter = Bouncy::Providers::Ses.new
    envelope = JSON.parse(confirmation)
    Bouncy.events.stub(:exists?, false) do
      Bouncy.stub(:events, Bouncy.events) do
        assert adapter.control(envelope)
        assert adapter.control(envelope)
      end
    end
    assert_equal 1, Bouncy.events.where(kind: "subscription_confirmed").count
  end

  private

  def confirmation(overrides = {})
    signed_envelope({ "Type" => "SubscriptionConfirmation", "MessageId" => "confirmation-1", "Token" => "fictional",
                      "SubscribeURL" => URL, "Message" => "You have chosen to subscribe" }.merge(overrides))
  end

  def post(body)
    Bouncy::Webhook.new.call("REQUEST_METHOD" => "POST", "rack.input" => StringIO.new(body), "CONTENT_TYPE" => "text/plain").first
  end
end
