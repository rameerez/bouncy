# frozen_string_literal: true

require "aws-sdk-sns"
require "openssl"
require "base64"

module SignedSns
  TOPIC = "arn:aws:sns:us-east-1:123456789012:feedback"
  CERT_URL = "https://sns.us-east-1.amazonaws.com/SimpleNotificationService-test.pem"
  KEY = OpenSSL::PKey::RSA.new(2048)
  CERT = OpenSSL::X509::Certificate.new.tap do |cert|
    cert.version = 2
    cert.serial = 1
    cert.subject = cert.issuer = OpenSSL::X509::Name.parse("/CN=sns.us-east-1.amazonaws.com")
    cert.public_key = KEY.public_key
    cert.not_before = Time.now - 3600
    cert.not_after = Time.now + 86_400
    cert.sign(KEY, OpenSSL::Digest.new("SHA256"))
  end

  def signed_envelope(overrides = {}, version: "2", **fields)
    overrides = overrides.merge(fields)
    envelope = {
      "Type" => "Notification", "MessageId" => "sns-message-1", "TopicArn" => TOPIC,
      "Timestamp" => Time.current.iso8601, "SignatureVersion" => version, "SigningCertURL" => CERT_URL,
      "Message" => JSON.generate("notificationType" => "Bounce", "bounce" => {
                                   "bounceType" => "Permanent", "bounceSubType" => "General", "feedbackId" => "feedback-1",
                                   "timestamp" => Time.current.iso8601,
                                   "bouncedRecipients" => [{ "emailAddress" => "Ada@Example.com" }, { "emailAddress" => "ben@example.com" }]
                                 })
    }.merge(overrides)
    canonical = Aws::SNS::MessageVerifier::SIGNABLE_KEYS.filter_map do |key|
      value = envelope[key]
      "#{key}\n#{value}\n" unless value.nil? || value.empty?
    end.join
    digest = version == "1" ? OpenSSL::Digest.new("SHA1") : OpenSSL::Digest.new("SHA256")
    envelope["Signature"] = Base64.strict_encode64(KEY.sign(digest, canonical))
    JSON.generate(envelope)
  end
end
