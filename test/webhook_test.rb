# frozen_string_literal: true

require "test_helper"
require "support/signed_sns"

class WebhookTest < BouncyTest
  include SignedSns

  def setup
    super
    Bouncy.configuration.adapter = nil
    Bouncy.configuration.ses.region = "us-east-1"
    Bouncy.configuration.ses.topic_arns = [TOPIC]
    Bouncy.configuration.ses.sns_client = Aws::SNS::Client.new(region: "us-east-1", stub_responses: true)
    stub_request(:get, CERT_URL).to_return(body: CERT.to_pem)
  end

  test "real RSA signatures 1 and 2 commit every recipient before success" do
    %w[1 2].each do |version|
      assert_equal 200, post(signed_envelope({}, version: version))
      assert Bouncy.blocked?("ada@example.com")
      assert Bouncy.blocked?("ben@example.com")
    end
    assert_equal 2, Bouncy.events.count
  end

  test "a validly signed foreign topic is unauthorized before any certificate fetch" do
    assert_equal 401, post(signed_envelope("TopicArn" => "arn:aws:sns:us-east-1:999999999999:feedback"))
    assert_not_requested :get, CERT_URL
    assert_empty Bouncy.events
  end

  test "missing allowlist rejects even authentic messages in test environment" do
    Bouncy.configuration.ses.topic_arns = []
    assert_equal 401, post(signed_envelope)
  end

  test "a string allowlist cannot authorize a topic by substring matching" do
    Bouncy.configuration.ses.topic_arns = "#{TOPIC}-different-topic"
    assert_equal 401, post(signed_envelope)
  end

  test "tampered and unknown signatures fail without storing policy" do
    envelope = JSON.parse(signed_envelope)
    envelope["Message"] += " "
    assert_equal 401, post(JSON.generate(envelope))
    envelope["SignatureVersion"] = "9"
    assert_equal 401, post(JSON.generate(envelope))
    assert_empty Bouncy.blocked
  end

  test "certificate URLs are restricted to exact HTTPS SNS locations" do
    ["http://sns.us-east-1.amazonaws.com/SimpleNotificationService-test.pem",
     "https://sns.us-east-1.amazonaws.com.attacker.invalid/SimpleNotificationService-test.pem",
     "https://user@sns.us-east-1.amazonaws.com/SimpleNotificationService-test.pem",
     "https://sns.us-east-1.amazonaws.com:444/SimpleNotificationService-test.pem",
     "https://sns.us-east-1.amazonaws.com/other.pem", "#{CERT_URL}?redirect=bad", "#{CERT_URL}#fragment"].each do |url|
      assert_equal 401, post(signed_envelope("SigningCertURL" => url)), url
    end
  end

  test "certificate network and HTTP failures remain retryable" do
    stub_request(:get, CERT_URL).to_timeout
    assert_equal 503, post(signed_envelope)
    stub_request(:get, CERT_URL).to_return(status: 302, headers: { "Location" => "https://attacker.invalid" })
    assert_equal 503, post(signed_envelope)
    assert_empty Bouncy.events
  end

  test "malformed or oversized certificates are rejected" do
    stub_request(:get, CERT_URL).to_return(body: "not a cert")
    assert_equal 401, post(signed_envelope)
    stub_request(:get, CERT_URL).to_return(body: "x" * (65 * 1024))
    assert_equal 401, post(signed_envelope)
  end

  test "bounded body read does not trust Content-Length" do
    input = StringIO.new("x" * (Bouncy::Webhook::BODY_LIMIT + 100))
    status, = Bouncy::Webhook.new.call("REQUEST_METHOD" => "POST", "rack.input" => input, "CONTENT_LENGTH" => "1")
    assert_equal 413, status
    assert_equal Bouncy::Webhook::BODY_LIMIT + 1, input.pos
  end

  test "malformed input and non string signed fields return 400" do
    ["{", "[]", "{}", JSON.generate(JSON.parse(signed_envelope).merge("Subject" => 42))].each do |body|
      assert_equal 400, post(body)
    end
    assert_equal 400, post(signed_envelope("Message" => "{"))
    assert_equal 400, post(signed_envelope("Type" => "Other"))
    assert_equal 405, Bouncy::Webhook.new.call("REQUEST_METHOD" => "GET").first
  end

  test "database failure returns 503 and retry completes state without duplicates" do
    original = Bouncy::Event.method(:create!)
    Bouncy::Event.stub(:create!, lambda { |attributes|
      raise ActiveRecord::ConnectionNotEstablished if attributes[:email] == "ben@example.com"

      original.call(attributes)
    }) do
      assert_equal 503, post(signed_envelope)
    end
    assert_equal 1, Bouncy.events.count
    assert Bouncy.blocked?("ada@example.com")
    refute Bouncy.blocked?("ben@example.com")
    assert_equal 200, post(signed_envelope)
    assert_equal 2, Bouncy.events.count
  end

  test "subscription confirmation calls SNS only after authentication" do
    overrides = { "Type" => "SubscriptionConfirmation", "Token" => "token", "SubscribeURL" => "https://attacker.invalid" }
    assert_equal 200, post(signed_envelope(overrides))
    assert_equal :confirm_subscription, Bouncy.configuration.ses.sns_client.api_requests.last[:operation_name]
    assert_equal 401, post(signed_envelope(overrides.merge("TopicArn" => "arn:aws:sns:us-east-1:999999999999:foreign")))
    assert_equal 1, Bouncy.configuration.ses.sns_client.api_requests.size
  end

  test "unexpected implementation errors are not converted into successful ingestion" do
    Bouncy::Ingestor.stub(:new, -> { raise NoMethodError, "bug" }) do
      assert_raises(NoMethodError) { post(signed_envelope) }
    end
  end

  test "SDK Lambda alias cannot substitute an unchecked certificate URL" do
    assert_equal 400, post(signed_envelope("SigningCertUrl" => "https://sns.eu-west-1.amazonaws.com/unchecked.pem"))
    assert_not_requested :get, CERT_URL
  end

  private

  def post(body)
    Bouncy::Webhook.new.call("REQUEST_METHOD" => "POST", "rack.input" => StringIO.new(body), "CONTENT_TYPE" => "text/plain").first
  end
end
