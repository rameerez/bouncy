# frozen_string_literal: true

require "test_helper"
require "support/signed_sns"

# A host that mounts the engine needs to test its own receiver route without
# reaching the network for Amazon's signing certificate.
# config.ses.sns_message_verifier replaces that download and nothing else, so
# the topic allowlist and the certificate-URL check still run against the
# host's real configuration.
class ReceiverSeamTest < BouncyTest
  include SignedSns

  class LocalCertificate < Aws::SNS::MessageVerifier
    private

    def https_get(*) = SignedSns::CERT.to_pem
  end

  def setup
    super
    Bouncy.configuration.adapter = nil
    Bouncy.configuration.ses.region = "us-east-1"
    Bouncy.configuration.ses.topic_arns = [SignedSns::TOPIC]
    Bouncy.configuration.ses.sns_message_verifier = LocalCertificate.new
  end

  def post(body)
    Bouncy::Webhook.new.call("REQUEST_METHOD" => "POST", "rack.input" => StringIO.new(body))
  end

  test "an authentic message from an allowed topic is accepted without a certificate download" do
    status, = post(signed_envelope)

    assert_equal 200, status
    assert Bouncy.blocked?("ada@example.com")
  end

  test "the injected verifier does not bypass topic authorization" do
    foreign = "arn:aws:sns:us-east-1:999999999999:attacker"
    status, = post(signed_envelope("TopicArn" => foreign))

    assert_equal 401, status
    assert_equal 0, Bouncy::Suppression.count
  end

  test "the injected verifier does not bypass the certificate URL check" do
    status, = post(signed_envelope("SigningCertURL" => "https://example.com/SimpleNotificationService-evil.pem"))

    assert_equal 401, status
    assert_equal 0, Bouncy::Suppression.count
  end

  test "a tampered body still fails the real signature check" do
    envelope = JSON.parse(signed_envelope)
    envelope["Message"] = JSON.generate("notificationType" => "Bounce", "bounce" => { "bounceType" => "Permanent" })

    status, = post(JSON.generate(envelope))

    assert_equal 401, status
    assert_equal 0, Bouncy::Suppression.count
  end
end
