# frozen_string_literal: true

require "test_helper"
require "aws-sdk-sns"
require "bouncy/providers/sns_verifier"
require "support/signed_sns"

class SnsVerifierTest < BouncyTest
  test "refuses an SDK that no longer exposes the certificate hooks it bounds" do
    Aws::SNS::MessageVerifier.stub(:private_method_defined?, false) do
      error = assert_raises(Bouncy::ConfigurationError) { Bouncy::Providers::SnsVerifier.new(Bouncy.configuration) }
      assert_match(/aws-sdk-sns/, error.message)
    end
    assert Bouncy::Providers::SnsVerifier.new(Bouncy.configuration)
  end

  test "the certificate cache keeps at most 16 URLs for an hour, across verifiers" do
    cache = Bouncy::Providers::SnsVerifier::CERTIFICATES
    downloads = []
    url = ->(index) { "https://sns.us-east-1.amazonaws.com/SimpleNotificationService-#{index}.pem" }
    download = lambda do |verifier, index|
      verifier.stub(:download_pem, ->(uri) { downloads << uri.to_s and SignedSns::CERT.to_pem }) { verifier.send(:pem, URI(url.call(index))) }
    end

    17.times { |index| download.call(Bouncy::Providers::SnsVerifier::BoundedVerifier.new, index) }
    assert_equal 16, cache.size
    download.call(Bouncy::Providers::SnsVerifier::BoundedVerifier.new, 16)
    assert_equal 17, downloads.size, "a new verifier still finds the cached certificate"
    download.call(Bouncy::Providers::SnsVerifier::BoundedVerifier.new, 0)
    assert_equal 18, downloads.size, "the oldest certificate left the cache"

    travel 61.minutes
    download.call(Bouncy::Providers::SnsVerifier::BoundedVerifier.new, 16)
    assert_equal 19, downloads.size, "an expired certificate is fetched again"
    refute cache.forget(url.call(16), after: 60), "a certificate fetched less than a minute ago stays"
    travel 2.minutes
    assert cache.forget(url.call(16), after: 60)
    refute cache.forget(url.call(99), after: 60)
  end
end
