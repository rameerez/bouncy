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

  test "a cold genuine certificate verifies during rotating forged certificate pressure" do
    bogus = stub_request(:get, %r{\Ahttps://sns\.us-east-1\.amazonaws\.com/SimpleNotificationService-forged\d+\.pem\z})
            .to_return do
      sleep 0.001
      { status: 404 }
    end
    template = JSON.parse(signed_envelope)
    ready = Queue.new
    threads = Array.new(4) do |worker|
      Thread.new do
        verifier = Bouncy::Providers::SnsVerifier.new(Bouncy.configuration)
        ready << true
        40.times do |index|
          body = template.merge("SigningCertURL" => "https://sns.us-east-1.amazonaws.com/SimpleNotificationService-forged#{(worker * 40) + index}.pem",
                                "Signature" => Base64.strict_encode64("forged"))
          begin
            verifier.call(JSON.generate(body))
          rescue Bouncy::ProviderError, Bouncy::AuthenticationError
            # The forged request is refused; the worker continues under pressure.
          end
        end
      end
    end
    4.times { ready.pop }
    verified = Bouncy::Providers::SnsVerifier.new(Bouncy.configuration).call(signed_envelope)
    assert_equal TOPIC, verified.fetch("TopicArn")
    threads.each(&:value)
    assert_requested bogus, times: 160
    assert_requested :get, CERT_URL, times: 1
  end

  test "default admission allows a genuine certificate while multiple forged downloads are blocked" do
    assert_nil Bouncy.configuration.sns_certificate_fetch_concurrency
    cache = Bouncy::Providers::SnsVerifier::CERTIFICATES
    started = Queue.new
    release = Queue.new
    threads = Array.new(4) do |index|
      Thread.new do
        cache.fetch("forged-#{index}") do
          started << true
          release.pop
          raise Bouncy::ProviderError, "synthetic 404"
        end
      rescue Bouncy::ProviderError
        nil
      end
    end
    4.times { started.pop }
    genuine = Thread.new { Bouncy::Providers::SnsVerifier.new(Bouncy.configuration).call(signed_envelope) }
    begin
      assert genuine.join(3), "genuine verification must not wait for forged downloads"
      assert_equal TOPIC, genuine.value.fetch("TopicArn")
    ensure
      4.times { release << true }
      threads.each(&:join)
      genuine.join
    end
  end

  test "the verifier passes the configured opt-in cap to its shared certificate cache" do
    Bouncy.configuration.sns_certificate_fetch_concurrency = 1
    cache = Bouncy::Providers::SnsVerifier::CERTIFICATES
    observed = nil
    replacement = lambda do |_url, concurrency:, &block|
      observed = concurrency
      block.call
    end
    verifier = Bouncy::Providers::SnsVerifier::BoundedVerifier.new(Bouncy.configuration)
    cache.stub(:fetch, replacement) { verifier.send(:pem, URI(CERT_URL)) }
    assert_equal 1, observed
  end

  test "the optional certificate cap accepts only positive integers" do
    [0, -1, 1.5, "2", false].each do |value|
      Bouncy.configuration.sns_certificate_fetch_concurrency = value
      assert_raises(Bouncy::ConfigurationError) { Bouncy.configuration.validate! }
    end
    [nil, 1, 2].each do |value|
      Bouncy.configuration.sns_certificate_fetch_concurrency = value
      assert Bouncy.configuration.validate!
    end
  end

  test "a new signing URL verifies after a previous certificate was cached" do
    assert_equal TOPIC, Bouncy::Providers::SnsVerifier.new(Bouncy.configuration).call(signed_envelope).fetch("TopicArn")
    rotated = "https://sns.us-east-1.amazonaws.com/SimpleNotificationService-rotated.pem"
    stub_request(:get, rotated).to_return(body: CERT.to_pem)
    assert_equal TOPIC, Bouncy::Providers::SnsVerifier.new(Bouncy.configuration).call(signed_envelope("SigningCertURL" => rotated)).fetch("TopicArn")
    assert_requested :get, rotated, times: 1
  end

  test "a waiting download gets a released slot, and a long wait is bounded" do
    cache = Cache.new(size: 16, ttl: 3600, concurrency: 1, wait: 0.1)
    gate = Queue.new
    started = Queue.new
    first = Thread.new do
      cache.fetch("first") do
        started << true
        gate.pop
        "first"
      end
    end
    started.pop
    error = assert_raises(Bouncy::ProviderError) { cache.fetch("second") { "second" } }
    assert_match(/in progress/, error.message)
    waiter = Thread.new { cache.fetch("third") { "third" } }
    gate << true
    assert_equal "first", first.value
    assert_equal "third", waiter.value
  end

  test "a remembered failure raises its own error class, and the failure list is bounded" do
    cache = Cache.new(size: 16, ttl: 3600, failures: 2)
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
