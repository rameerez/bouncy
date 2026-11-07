# frozen_string_literal: true

# rubocop:disable Style/RedundantFetchBlock -- CertificateCache#fetch takes the download as its block; it is not Hash#fetch.

require "test_helper"
require "support/signed_sns"
require "bouncy/providers/sns_verifier"

class CertificatePressureTest < BouncyTest
  include SignedSns

  Cache = Bouncy::Providers::SnsVerifier::CertificateCache

  def setup
    super
    Bouncy.configuration.adapter = nil
    Bouncy.configuration.ses.region = "us-east-1"
    Bouncy.configuration.ses.topic_arns = [TOPIC]
    stub_request(:get, CERT_URL).to_return(body: CERT.to_pem)
  end

  test "a failed download is remembered briefly, so retries of one URL do not fetch it again" do
    stub_request(:get, CERT_URL).to_return(status: 404)
    assert_equal 503, post(signed_envelope("MessageId" => "m-1"))
    assert_equal 503, post(signed_envelope("MessageId" => "m-2"))
    assert_requested :get, CERT_URL, times: 1
    travel 11.seconds
    stub_request(:get, CERT_URL).to_return(body: CERT.to_pem)
    assert_equal 200, post(signed_envelope("MessageId" => "m-3")), "SNS's retry 20 seconds later finds the certificate"
  end

  test "forged messages that rotate the certificate file name get a bounded number of downloads" do
    bogus = stub_request(:get, %r{\Ahttps://sns\.us-east-1\.amazonaws\.com/SimpleNotificationService-forged\d+\.pem\z}).to_return(status: 404)
    statuses = Array.new(15) do |index|
      body = JSON.parse(signed_envelope("MessageId" => "f-#{index}",
                                        "SigningCertURL" => "https://sns.us-east-1.amazonaws.com/SimpleNotificationService-forged#{index}.pem"))
      body["Signature"] = Base64.strict_encode64("forged")
      post(JSON.generate(body))
    end
    assert_equal [503], statuses.uniq
    assert_requested bogus, times: 10
    travel 61.seconds
    assert_equal 200, post(signed_envelope("MessageId" => "m-1")), "the budget refills"
  end

  test "a URL that verified a signature is fetched again outside the budget" do
    cache = Cache.new(size: 16, ttl: 3600, budget: 3, window: 60)
    good = "https://sns.us-east-1.amazonaws.com/SimpleNotificationService-good.pem"
    cache.fetch(good) { "pem" }
    cache.trust(good)
    2.times { |index| cache.fetch("https://sns.us-east-1.amazonaws.com/SimpleNotificationService-x#{index}.pem") { "pem" } }
    error = assert_raises(Bouncy::ProviderError) { cache.fetch("https://sns.us-east-1.amazonaws.com/SimpleNotificationService-y.pem") { "pem" } }
    assert_match(/budget/, error.message)
    travel 61.minutes
    assert_equal "new", cache.fetch(good) { "new" }, "the trusted certificate expired and is fetched despite an exhausted budget"
  end

  test "at most two downloads run at once; a third request fails fast and retries later" do
    cache = Cache.new(size: 16, ttl: 3600)
    gate = Queue.new
    started = Queue.new
    threads = Array.new(2) do |index|
      Thread.new do
        cache.fetch("https://sns.us-east-1.amazonaws.com/SimpleNotificationService-#{index}.pem") do
          started << index
          gate.pop
          "pem-#{index}"
        end
      end
    end
    2.times { started.pop }
    error = assert_raises(Bouncy::ProviderError) { cache.fetch("https://sns.us-east-1.amazonaws.com/SimpleNotificationService-2.pem") { "pem" } }
    assert_match(/in progress/, error.message)
    2.times { gate << :go }
    assert_equal %w[pem-0 pem-1], threads.map(&:value)
    assert_equal "pem", cache.fetch("https://sns.us-east-1.amazonaws.com/SimpleNotificationService-2.pem") { "pem" }
  end

  test "a remembered failure raises its own error class, and the failure list is bounded" do
    cache = Cache.new(size: 16, ttl: 3600, failures: 2, budget: 100)
    urls = Array.new(3) { |index| "https://sns.us-east-1.amazonaws.com/SimpleNotificationService-#{index}.pem" }
    urls.each do |url|
      assert_raises(Aws::SNS::MessageVerifier::VerificationError) do
        cache.fetch(url) { raise Aws::SNS::MessageVerifier::VerificationError, "does not parse" }
      end
    end
    error = assert_raises(Aws::SNS::MessageVerifier::VerificationError) { cache.fetch(urls.last) { flunk "fetched again" } }
    assert_equal "does not parse", error.message
    assert_equal "pem", cache.fetch(urls.first) { "pem" }, "the oldest failure left the list"
  end

  private

  def post(body)
    Bouncy::Webhook.new.call("REQUEST_METHOD" => "POST", "rack.input" => StringIO.new(body)).first
  end
end
# rubocop:enable Style/RedundantFetchBlock
