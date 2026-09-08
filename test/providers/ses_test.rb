# frozen_string_literal: true

require "test_helper"
require "aws-sdk-sesv2"
require "aws-sdk-sns"
require "aws-sdk-sts"

class SesTest < BouncyTest
  def setup
    super
    @ses = Aws::SESV2::Client.new(region: "us-east-1", stub_responses: true)
    @sts = Aws::STS::Client.new(region: "us-east-1", stub_responses: true)
    @sns = Aws::SNS::Client.new(region: "us-east-1", stub_responses: true)
    Bouncy.configure do |config|
      config.ses.region = "us-east-1"
      config.ses.client = @ses
      config.ses.sts_client = @sts
      config.ses.sns_client = @sns
      config.ses.all_sending_paths_listed = true
    end
    @sts.stub_responses(:get_caller_identity, account: "123456789012")
    @ses.stub_responses(:get_account, suppression_attributes: { suppressed_reasons: %w[BOUNCE COMPLAINT] })
    @adapter = Bouncy::Providers::Ses.new
  end

  test "enumerates every page without a date filter and retains exact identifiers" do
    @ses.stub_responses(:list_suppressed_destinations, [
                          { suppressed_destination_summaries: [summary("Ada@Example.com")], next_token: "page2" },
                          { suppressed_destination_summaries: [summary("BEN@example.com", reason: "COMPLAINT")] }
                        ])
    snapshot = @adapter.snapshot
    assert snapshot.complete
    assert snapshot.policy_verified
    assert_equal %w[Ada@Example.com BEN@example.com], snapshot.entries.map(&:email)
    assert_equal %i[hard_bounce complaint], snapshot.entries.map(&:reason)
    requests = @ses.api_requests.select { |request| request[:operation_name] == :list_suppressed_destinations }
    assert_equal([nil, "page2"], requests.map { |request| request[:params][:next_token] })
    assert(requests.none? { |request| request[:params].key?(:start_date) })
  end

  test "failed or looping pagination never pretends to be complete" do
    @ses.stub_responses(:list_suppressed_destinations, [
                          { suppressed_destination_summaries: [summary("a@example.com")], next_token: "again" }, "TooManyRequestsException"
                        ])
    assert_raises(Bouncy::ProviderError) { @adapter.snapshot }
    @ses.stub_responses(:list_suppressed_destinations, suppressed_destination_summaries: [], next_token: "again")
    assert_raises(Bouncy::ProviderError) { @adapter.snapshot }
  end

  test "release deletes exact variants and verifies each absence" do
    @ses.stub_responses(:get_suppressed_destination, "NotFoundException")
    @adapter.release([entry, entry("ADA@example.com")])
    operations = @ses.api_requests.map { |request| [request[:operation_name], request[:params][:email_address]] }
    assert_equal [[:delete_suppressed_destination, "Ada@Example.com"], [:get_suppressed_destination, "Ada@Example.com"],
                  [:delete_suppressed_destination, "ADA@example.com"], [:get_suppressed_destination, "ADA@example.com"]], operations
  end

  test "not found from exact delete still requires an exact read" do
    @ses.stub_responses(:delete_suppressed_destination, "NotFoundException")
    @ses.stub_responses(:get_suppressed_destination, "NotFoundException")
    @adapter.release([entry])
    assert_equal 2, @ses.api_requests.size
    @ses.stub_responses(:get_suppressed_destination, suppressed_destination: summary("Ada@Example.com"))
    assert_raises(Bouncy::ProviderError) { @adapter.release([entry]) }
  end

  test "access denial and transport failures are typed failures" do
    @ses.stub_responses(:delete_suppressed_destination, "BadRequestException")
    assert_raises(Bouncy::ProviderError) { @adapter.release([entry]) }
    @ses.stub_responses(:get_suppressed_destination, Seahorse::Client::NetworkingError.new(IOError.new("offline")))
    assert_raises(Bouncy::ProviderError) { @adapter.lookup("Ada@Example.com") }
  end

  test "partial recovery reports confirmed failed and unattempted variants" do
    @ses.stub_responses(:delete_suppressed_destination, [{}, "BadRequestException"])
    @ses.stub_responses(:get_suppressed_destination, "NotFoundException")
    error = assert_raises(Bouncy::ReleaseFailed) { @adapter.release([entry, entry("ADA@example.com"), entry("ada@example.COM")]) }
    assert_equal(%w[removed failed not_attempted], error.outcomes.map { |outcome| outcome["result"] })
    assert_equal "ADA@example.com", error.outcomes[1]["email"]
  end

  test "credentials and injected client must match account and region" do
    @sts.stub_responses(:get_caller_identity, account: "999999999999")
    assert_raises(Bouncy::UnsafeSnapshot) { @adapter.snapshot }
    @sts.stub_responses(:get_caller_identity, account: "123456789012")
    Bouncy.configuration.ses.client = Aws::SESV2::Client.new(region: "eu-west-1", stub_responses: true)
    assert_raises(Bouncy::UnsafeSnapshot) { Bouncy::Providers::Ses.new.snapshot }
    Bouncy.configuration.ses.region = nil
    assert_raises(Bouncy::ConfigurationError) { @adapter.snapshot }
  end

  test "effective policy must cover both reasons and configured sending sets" do
    Bouncy.configuration.ses.all_sending_paths_listed = false
    snapshot = @adapter.snapshot
    refute snapshot.policy_verified
    assert_match(/all_sending_paths_listed is false/, snapshot.policy_reason)
    Bouncy.configuration.ses.all_sending_paths_listed = true
    @ses.stub_responses(:get_account, suppression_attributes: { suppressed_reasons: ["BOUNCE"] })
    snapshot = @adapter.snapshot
    refute snapshot.policy_verified
    assert_match(/covers \["BOUNCE"\]/, snapshot.policy_reason)
    @ses.stub_responses(:get_account, suppression_attributes: { suppressed_reasons: %w[BOUNCE COMPLAINT] })
    Bouncy.configuration.ses.identities = ["example.com"]
    @ses.stub_responses(:get_email_identity, configuration_set_name: "transactional")
    @ses.stub_responses(:get_configuration_set, suppression_options: { suppressed_reasons: [] })
    snapshot = @adapter.snapshot
    refute snapshot.policy_verified
    assert_match(/configuration set transactional overrides/, snapshot.policy_reason)
    @ses.stub_responses(:get_configuration_set, suppression_options: { suppressed_reasons: %w[COMPLAINT BOUNCE] })
    assert @adapter.snapshot.policy_verified
    @ses.stub_responses(:get_configuration_set, {})
    assert @adapter.snapshot.policy_verified
    @ses.stub_responses(:get_email_identity, {})
    assert @adapter.snapshot.policy_verified, "an identity without a configuration set uses the account policy"
    @ses.stub_responses(:get_account, {})
    snapshot = @adapter.snapshot
    refute snapshot.policy_verified
    assert_match(/covers \[\]/, snapshot.policy_reason)
  end

  test "control confirmation uses signed token and topic rather than SubscribeURL" do
    assert @adapter.control("Type" => "SubscriptionConfirmation", "TopicArn" => "arn:aws:sns:us-east-1:123456789012:feedback",
                            "Token" => "signed-token", "SubscribeURL" => "https://attacker.invalid/")
    assert_equal({ topic_arn: "arn:aws:sns:us-east-1:123456789012:feedback", token: "signed-token" }, @sns.api_requests.last[:params])
    assert @adapter.control("Type" => "UnsubscribeConfirmation")
    refute @adapter.control("Type" => "Notification")
    assert_equal 1, @sns.api_requests.size
  end

  test "doctor performs reads only and does not claim write authorization" do
    Bouncy.configuration.ses.topic_arns = ["arn:aws:sns:us-east-1:123456789012:feedback"]
    @sns.stub_responses(:get_topic_attributes, attributes: { "Policy" => JSON.generate("Statement" => []) })
    checks = @adapter.doctor
    assert checks["policy_verified"]
    assert_nil checks["policy_reason"]
    assert_match(/unknown/, checks["write_permissions"])
    assert((@ses.api_requests + @sts.api_requests + @sns.api_requests).all? { |request| request[:operation_name].to_s.start_with?("get_") })
  end

  private

  def summary(email, reason: "BOUNCE")
    { email_address: email, reason: reason, last_update_time: Time.current }
  end
end
