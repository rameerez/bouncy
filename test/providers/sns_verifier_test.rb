# frozen_string_literal: true

require "test_helper"
require "aws-sdk-sns"
require "bouncy/providers/sns_verifier"

class SnsVerifierTest < BouncyTest
  test "refuses an SDK that no longer exposes the certificate hooks it bounds" do
    Aws::SNS::MessageVerifier.stub(:private_method_defined?, false) do
      error = assert_raises(Bouncy::ConfigurationError) { Bouncy::Providers::SnsVerifier.new(Bouncy.configuration) }
      assert_match(/aws-sdk-sns/, error.message)
    end
    assert Bouncy::Providers::SnsVerifier.new(Bouncy.configuration)
  end

  test "the certificate cache is bounded and tolerates a missing cache" do
    verifier = Bouncy::Providers::SnsVerifier::BoundedVerifier.new
    verifier.instance_variable_set(:@cached_pems, nil)
    verifier.stub(:download_pem, ->(uri) { "pem for #{uri}" }) do
      33.times { |index| verifier.send(:pem, URI("https://sns.us-east-1.amazonaws.com/SimpleNotificationService-#{index}.pem")) }
      assert_equal 32, verifier.instance_variable_get(:@cached_pems).size
      assert_equal "pem for https://sns.us-east-1.amazonaws.com/SimpleNotificationService-32.pem",
                   verifier.send(:pem, URI("https://sns.us-east-1.amazonaws.com/SimpleNotificationService-32.pem"))
    end
  end
end
