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

  test "empty and already consumed request streams are rejected without provider work" do
    [StringIO.new(""), StringIO.new(signed_envelope)].each do |input|
      input.read
      status, = Bouncy::Webhook.new.call("REQUEST_METHOD" => "POST", "rack.input" => input)
      assert_equal 400, status
    end
    assert_empty Bouncy.events
    assert_not_requested :get, CERT_URL
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
    assert_equal({ "via" => "api" }, Bouncy.events.where(kind: "subscription_confirmed").sole.details)
    assert_equal 401, post(signed_envelope(overrides.merge("TopicArn" => "arn:aws:sns:us-east-1:999999999999:foreign")))
    assert_equal 1, Bouncy.configuration.ses.sns_client.api_requests.size
  end

  test "with subscribe_url a signed confirmation of the topic is confirmed on its SNS URL only" do
    Bouncy.configuration.ses.subscription_confirmation = :subscribe_url
    url = "https://sns.us-east-1.amazonaws.com/?Action=ConfirmSubscription&TopicArn=#{TOPIC}&Token=fictional"
    confirmation = stub_request(:get, url).to_return(status: 200, body: "<ConfirmSubscriptionResponse/>")
    overrides = { "Type" => "SubscriptionConfirmation", "Token" => "fictional", "SubscribeURL" => url }

    assert_equal 200, post(signed_envelope(overrides))
    ["https://confirm.example.com/", "http://sns.us-east-1.amazonaws.com/", "https://sns.eu-west-1.amazonaws.com/",
     "https://user@sns.us-east-1.amazonaws.com/", "https://sns.us-east-1.amazonaws.com:8443/", "#{url}#fragment",
     "https://sns.us-east-1.amazonaws.com/%"].each do |other|
      assert_equal 400, post(signed_envelope(overrides.merge("SubscribeURL" => other))), other
    end
    assert_equal 401, post(signed_envelope(overrides.merge("TopicArn" => "arn:aws:sns:us-east-1:999999999999:feedback")))

    assert_requested confirmation, times: 1
    assert_empty Bouncy.configuration.ses.sns_client.api_requests, "no sns:ConfirmSubscription call"
    assert_equal({ "via" => "subscribe_url" }, Bouncy.events.where(kind: "subscription_confirmed").sole.details)
  end

  test "a confirmation visit that does not answer 2xx answers 503, so SNS sends the confirmation again" do
    Bouncy.configuration.ses.subscription_confirmation = :subscribe_url
    url = "https://sns.us-east-1.amazonaws.com/?Action=ConfirmSubscription&TopicArn=#{TOPIC}&Token=fictional"
    body = signed_envelope("Type" => "SubscriptionConfirmation", "Token" => "fictional", "SubscribeURL" => url)

    stub_request(:get, url).to_return(status: 500)
    assert_equal 503, post(body)
    stub_request(:get, url).to_return(status: 302, headers: { "Location" => "https://attacker.example.com/" })
    assert_equal 503, post(body)
    stub_request(:get, url).to_timeout
    assert_equal 503, post(body)
    stub_request(:get, url).to_raise(Errno::ECONNREFUSED)
    assert_equal 503, post(body)
    stub_request(:get, url).to_return(status: 200, body: "x" * (65 * 1024))
    assert_equal 503, post(body)
    assert_empty Bouncy.events
    assert_not_requested :get, "https://attacker.example.com/"

    stub_request(:get, url).to_return(status: 204)
    assert_equal 200, post(body)
    assert_equal 1, Bouncy.events.where(kind: "subscription_confirmed").count
  end

  test "messages that name one signing certificate fetch it once, a new URL fetches again, and an expired one is fetched again" do
    other = "https://sns.us-east-1.amazonaws.com/SimpleNotificationService-other.pem"
    stub_request(:get, other).to_return(body: CERT.to_pem)
    assert_equal 200, post(signed_envelope("MessageId" => "m-1"))
    assert_equal 200, post(signed_envelope("MessageId" => "m-2"))
    assert_requested :get, CERT_URL, times: 1
    assert_equal 200, post(signed_envelope("MessageId" => "m-3", "SigningCertURL" => other))
    assert_requested :get, other, times: 1
    travel 61.minutes
    assert_equal 200, post(signed_envelope("MessageId" => "m-4"))
    assert_requested :get, CERT_URL, times: 2
  end

  test "a certificate rotated at the same URL is fetched again once, but not within a minute of the last fetch" do
    key = OpenSSL::PKey::RSA.new(2048)
    rotated = OpenSSL::X509::Certificate.new.tap do |cert|
      cert.version = 2
      cert.serial = 2
      cert.subject = cert.issuer = OpenSSL::X509::Name.parse("/CN=sns.us-east-1.amazonaws.com")
      cert.public_key = key.public_key
      cert.not_before = Time.now - 3600
      cert.not_after = Time.now + 86_400
      cert.sign(key, OpenSSL::Digest.new("SHA256"))
    end
    assert_equal 200, post(signed_envelope("MessageId" => "m-1"))
    stub_request(:get, CERT_URL).to_return(body: rotated.to_pem)
    envelope = JSON.parse(signed_envelope("MessageId" => "m-2"))
    canonical = Aws::SNS::MessageVerifier::SIGNABLE_KEYS.filter_map { |name| "#{name}\n#{envelope[name]}\n" if envelope[name] }.join
    envelope["Signature"] = Base64.strict_encode64(key.sign(OpenSSL::Digest.new("SHA256"), canonical))

    assert_equal 401, post(JSON.generate(envelope)), "fetched seconds ago: no second download"
    assert_requested :get, CERT_URL, times: 1
    travel 2.minutes
    assert_equal 200, post(JSON.generate(envelope))
    assert_requested :get, CERT_URL, times: 2
  end

  test "every refusal logs one line with its reason and origin, and never an address or the body" do
    foreign = "arn:aws:sns:us-east-1:999999999999:feedback"
    log = logged do
      assert_equal 405, Bouncy::Webhook.new.call("REQUEST_METHOD" => "GET").first
      assert_equal 400, post("")
      assert_equal 413, post("x" * (Bouncy::Webhook::BODY_LIMIT + 1))
      tampered = JSON.parse(signed_envelope)
      tampered["Message"] += " "
      assert_equal 401, post(JSON.generate(tampered))
      assert_equal 401, post(signed_envelope("TopicArn" => foreign))
      assert_equal 400, post(signed_envelope("Type" => "Other"))
      Bouncy.configuration.scope = nil
      assert_equal 503, post(signed_envelope)
    end
    lines = log.lines.grep(/\[bouncy\] refused an SNS message/)
    assert_equal 7, lines.size, log
    assert_match(/\(405\): method GET is not POST/, lines[0])
    assert_match(/\(400\): empty body/, lines[1])
    assert_match(/\(413\): body over/, lines[2])
    assert_match(/\(401\): SNS signature could not be verified; topic #{TOPIC}/, lines[3])
    assert_match(/\(401\): SNS topic is not authorized; topic #{foreign}/, lines[4])
    assert_match(/\(400\): Unsupported SNS control type; topic #{TOPIC}/, lines[5])
    assert_match(/\(503\): Set config.scope/, lines[6])
    refute_match(/ada@example.com|ben@example.com|bounceType/i, log)
  end

  test "without a logger, refusals, hook failures and skipped jobs stay quiet" do
    previous = Rails.logger
    Rails.logger = nil
    Bouncy.configuration.on_notification = ->(_notification) { raise "the app's hook failed" }
    assert_equal 503, post(signed_envelope)
    assert_equal 400, post("")
    Bouncy.configuration.scope = nil
    assert_nil Bouncy::SyncJob.perform_now
    assert_nil Bouncy::PruneJob.perform_now
  ensure
    Rails.logger = previous
  end

  test "a failed subscription confirmation logs the topic and the SubscribeURL host" do
    url = "https://sns.us-east-1.amazonaws.com/?Action=ConfirmSubscription&TopicArn=#{TOPIC}&Token=fictional"
    confirmation = signed_envelope("Type" => "SubscriptionConfirmation", "Token" => "fictional", "SubscribeURL" => url)
    log = logged do
      Bouncy.configuration.ses.sns_client.stub_responses(:confirm_subscription, "AuthorizationError")
      assert_equal 503, post(confirmation)
      Bouncy.configuration.ses.subscription_confirmation = :subscribe_url
      stub_request(:get, url).to_return(status: 500)
      assert_equal 503, post(confirmation)
    end
    lines = log.lines.grep(/\[bouncy\] refused an SNS message/)
    assert_match(/\(503\): AWS request failed \(AuthorizationError\); topic #{TOPIC}; SubscribeURL host sns.us-east-1.amazonaws.com/, lines[0])
    assert_match(/\(503\): SNS did not confirm the subscription \(HTTP 500\); topic #{TOPIC}; SubscribeURL host sns.us-east-1.amazonaws.com/, lines[1])
    refute_match(/fictional/, log, "the token stays out of the log")
  end

  test "unexpected implementation errors are not converted into successful ingestion" do
    Bouncy::Ingestor.stub(:new, -> { raise NoMethodError, "bug" }) do
      assert_raises(NoMethodError) { post(signed_envelope) }
    end
  end

  test "a complaint naming one recipient blocks locally while several recipients stay candidates" do
    complaint = lambda do |recipients|
      JSON.generate("notificationType" => "Complaint", "complaint" => {
                      "feedbackId" => "complaint-#{recipients.size}", "timestamp" => Time.current.iso8601,
                      "complainedRecipients" => recipients.map { |email| { "emailAddress" => email } }
                    })
    end
    assert_equal 200, post(signed_envelope("Message" => complaint.call(%w[ada@example.com ben@example.com]), "MessageId" => "m-2"))
    refute Bouncy.blocked?("ada@example.com")
    assert_equal 200, post(signed_envelope("Message" => complaint.call(%w[ada@example.com]), "MessageId" => "m-1"))
    assert Bouncy.blocked?("ada@example.com")
    assert_equal :complaint, Bouncy.status("ada@example.com").reason
    refute Bouncy.blocked?("ben@example.com")
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
