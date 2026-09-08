# frozen_string_literal: true

require "test_helper"
require "aws-sdk-sesv2"
require "aws-sdk-sns"
require "aws-sdk-sts"

class DogfoodingRegressionsTest < BouncyTest
  test "message-related and unknown soft failures never escalate into an address hold" do
    Bouncy.configuration.soft_bounce_threshold = 2
    %w[MessageTooLarge ContentRejected AttachmentRejected General FutureSubtype].each do |subtype|
      3.times do |index|
        payload = { "eventType" => "Bounce", "bounce" => { "bounceType" => "Transient", "bounceSubType" => subtype,
                                                           "bouncedRecipients" => [{ "emailAddress" => "ada@example.com" }],
                                                           "feedbackId" => "#{subtype}-#{index}" } }
        observation = Bouncy::Providers::SesParser.new(Bouncy.configuration).call(
          "Message" => JSON.generate(payload), "MessageId" => "sns", "Timestamp" => Time.current.iso8601
        ).sole
        Bouncy::Ingestor.new.call(observation)
      end
    end
    refute Bouncy.blocked?("ada@example.com")
    assert_equal 0, Bouncy::Suppression.sole.soft_bounce_count
    assert_equal 15, Bouncy.events.count
  end

  test "out of order mailbox failures inside the current window still count" do
    Bouncy.configuration.soft_bounce_threshold = 3
    [1.day.ago, 3.days.ago, 2.days.ago].each { |time| observe(kind: "soft_bounce", time: time) }
    assert Bouncy.blocked?("ada@example.com")
    assert_equal 3, Bouncy::Suppression.sole.soft_bounce_count
  end

  test "recent soft evidence cannot hide a delayed hard bounce" do
    observe(kind: "soft_bounce")
    observe(kind: "hard_bounce", time: 1.minute.ago)
    assert_equal :hard_bounce, Bouncy.status("ada@example.com").reason
  end

  test "late mailbox failures outside the current window cannot create a new hold" do
    Bouncy.configuration.soft_bounce_threshold = 2
    [60.days.ago, 59.days.ago].each { |time| observe(kind: "soft_bounce", time: time) }
    assert_equal 0, Bouncy::Suppression.sole.soft_bounce_count
    refute Bouncy.blocked?("ada@example.com")
  end

  test "a local release fences delayed soft evidence but not hard provider evidence" do
    Bouncy.configuration.soft_bounce_threshold = 2
    Bouncy.release!("ada@example.com", at: :local)
    3.times { observe(kind: "soft_bounce", time: 1.minute.ago) }
    refute Bouncy.blocked?("ada@example.com")
    observe(kind: "hard_bounce", time: 1.minute.ago)
    assert Bouncy.blocked?("ada@example.com")
  end

  test "thresholds beyond retained capacity and malformed durations fail explicitly" do
    Bouncy.configuration.soft_bounce_threshold = 51
    assert_raises(Bouncy::ConfigurationError) { Bouncy.configuration.validate! }
    Bouncy.configuration.soft_bounce_threshold = nil
    [nil, "30 days", 0].each do |window|
      Bouncy.configuration.soft_bounce_window = window
      assert_raises(Bouncy::ConfigurationError) { Bouncy.configuration.validate! }
    end
  end

  test "bootstrap fails closed on unsupported policy and reuses a healthy mirror" do
    @provider.policy_verified = false
    assert_raises(Bouncy::UnsafeSnapshot) { Bouncy.bootstrap! }
    refute Bouncy.sync_fresh?
    @provider.policy_verified = true
    Bouncy.bootstrap!
    assert Bouncy.sync_fresh?
    assert_no_difference "Bouncy.events.count" do
      Bouncy.bootstrap!
    end
    Bouncy.configuration.stale_after = 1.minute
    travel 2.minutes
    refute Bouncy.sync_fresh?
    Bouncy.bootstrap!
    assert Bouncy.sync_fresh?
    Bouncy.configuration.scope = nil
    refute Bouncy.sync_fresh?
    assert_raises(Bouncy::ConfigurationError) { Bouncy.bootstrap! }
  end

  test "the same explicit credentials reach SES SNS and STS" do
    credentials = Aws::Credentials.new("synthetic-key", "synthetic-secret", "synthetic-session")
    Bouncy.configuration.ses.credentials = credentials
    Bouncy.configuration.ses.region = "us-east-1"
    adapter = Bouncy::Providers::Ses.new
    %i[client sns_client sts_client].each do |name|
      client = adapter.send(name)
      assert_same credentials, client.config.credentials
      assert_equal "us-east-1", client.config.region
    end
  end

  test "missing credentials become a diagnostic provider failure" do
    Bouncy.configuration.adapter = Bouncy::Providers::Ses.new
    adapter = Bouncy.adapter
    adapter.stub(:policy_check, -> { adapter.send(:request) { raise Aws::Errors::MissingCredentialsError } }) do
      assert_raises(Bouncy::ProviderError) { Bouncy.sync! }
    end
    refute Bouncy.sync_fresh?
    assert_equal "Bouncy::ProviderError", Bouncy.last_sync.details["error_class"]
  end
end
