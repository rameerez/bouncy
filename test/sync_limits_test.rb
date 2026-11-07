# frozen_string_literal: true

require "test_helper"
require "aws-sdk-sesv2"
require "aws-sdk-sns"
require "aws-sdk-sts"

class SyncLimitsTest < BouncyTest
  def setup
    super
    @ses = Aws::SESV2::Client.new(region: "us-east-1", stub_responses: true)
    @sts = Aws::STS::Client.new(region: "us-east-1", stub_responses: true)
    Bouncy.configure do |config|
      config.adapter = nil
      config.ses.region = "us-east-1"
      config.ses.client = @ses
      config.ses.sts_client = @sts
      config.ses.all_sending_paths_listed = true
    end
    @sts.stub_responses(:get_caller_identity, account: "123456789012")
    @ses.stub_responses(:get_account, suppression_attributes: { suppressed_reasons: %w[BOUNCE COMPLAINT] })
  end

  test "the SES scan hands over each page before it requests the next" do
    pages
    seen = []
    Bouncy::Providers::Ses.new.scan(Bouncy.configuration.sync_limits) do |page|
      seen << [page.entries.map(&:email), list_requests.size]
      assert page.authoritative
      assert page.policy_verified
    end
    assert_equal [[["a@example.com"], 1], [["b@example.com"], 2], [["c@example.com"], 3]], seen
  end

  test "each limit stops the scan as incomplete and says which one" do
    { sync_max_pages: [2, /page limit \(2\)/, 2], sync_max_entries: [1, /entry limit \(1\)/, 1] }.each do |setting, (value, reason, requests)|
      Bouncy.configuration.sync_max_pages = 1_000
      Bouncy.configuration.sync_max_entries = 1_000_000
      Bouncy.configuration.public_send("#{setting}=", value)
      @ses.api_requests.clear
      pages
      snapshot = Bouncy::Providers::Ses.new.scan(Bouncy.configuration.sync_limits) { |_page| nil }
      refute snapshot.complete, setting
      assert_match reason, snapshot.incomplete_reason
      assert_equal requests, list_requests.size, setting
    end

    Bouncy.configuration.sync_max_entries = 1_000_000
    Bouncy.configuration.sync_max_duration = 5.minutes
    @ses.api_requests.clear
    pages
    snapshot = Bouncy::Providers::Ses.new.scan(Bouncy.configuration.sync_limits) { |_page| travel 3.minutes }
    refute snapshot.complete
    assert_match(/time limit \(300s\)/, snapshot.incomplete_reason)
    assert_equal 2, list_requests.size, "the third page is never requested"
  end

  test "a truncated sync adds what it read, clears nothing, and is recorded incomplete" do
    gone = Bouncy::Suppression.create!(scope: Bouncy.scope, email: "gone@example.com", provider: "ses",
                                       provider_entries: [{ "email" => "gone@example.com", "reason" => "hard_bounce",
                                                            "provider_updated_at" => 2.days.ago.iso8601(6) }],
                                       provider_blocked_at: 2.days.ago, provider_reason: "hard_bounce")
    gone.summarize!
    @ses.stub_responses(:get_suppressed_destination, "NotFoundException")
    Bouncy.configuration.sync_max_pages = 2
    pages

    output = logged { Bouncy.sync! }
    sync = Bouncy.last_sync
    refute sync.details["complete"]
    refute sync.details["enumerated"]
    assert_match(/page limit/, sync.details["incomplete_reason"])
    assert_equal 2, sync.details["entries"]
    assert_match(/sync stopped before the end of the provider list: page limit \(2\) reached; no restriction was cleared/, output)
    assert Bouncy.blocked?("a@example.com")
    assert Bouncy.blocked?("b@example.com")
    refute Bouncy.blocked?("c@example.com"), "the third page was never read"
    assert Bouncy.blocked?("gone@example.com"), "absence from a truncated list proves nothing"
    assert(@ses.api_requests.none? { |request| request[:operation_name] == :get_suppressed_destination })

    Bouncy.configuration.sync_max_pages = 1_000
    pages
    Bouncy.sync!
    assert Bouncy.last_sync.details["complete"]
    assert_nil Bouncy.last_sync.details["incomplete_reason"]
    assert Bouncy.blocked?("c@example.com")
    refute Bouncy.blocked?("gone@example.com"), "a complete list checks the absence and releases"
  end

  test "spellings of one address on two pages both stay, and the second page is not taken for a concurrent change" do
    @ses.stub_responses(:list_suppressed_destinations, [
                          { suppressed_destination_summaries: [summary("Ada@Example.com")], next_token: "page2" },
                          { suppressed_destination_summaries: [summary("ADA@example.com", reason: "COMPLAINT")] }
                        ])
    @ses.stub_responses(:get_suppressed_destination, suppressed_destination: { email_address: "Ada@Example.com", reason: "BOUNCE",
                                                                               last_update_time: Time.current })
    Bouncy.sync!
    row = Bouncy::Suppression.find_by!(email: "ada@example.com")
    assert_equal %w[ADA@example.com Ada@Example.com], row.provider_entries.map { |entry| entry["email"] }.sort
    assert_equal "complaint", row.provider_reason
    assert_equal 1, Bouncy.last_sync.details["added"]
    assert_equal 1, Bouncy.last_sync.details["updated"], "the second page changed the reason; it was not skipped"
  end

  test "a provider release reads the whole list, keeps only the address's spellings, and refuses a truncated list" do
    @ses.stub_responses(:list_suppressed_destinations, [
                          { suppressed_destination_summaries: [summary("Ada@Example.com"), summary("ben@example.com")], next_token: "p2" },
                          { suppressed_destination_summaries: [summary("ADA@example.com")] }
                        ])
    @ses.stub_responses(:get_suppressed_destination, "NotFoundException")
    Bouncy.release!("ada@example.com", note: "Customer fixed their mailbox", actor: "support")
    deleted = @ses.api_requests.select { |request| request[:operation_name] == :delete_suppressed_destination }
    assert_equal(%w[ADA@example.com Ada@Example.com], deleted.map { |request| request[:params][:email_address] }.sort)

    @ses.api_requests.clear
    Bouncy.configuration.sync_max_pages = 1
    @ses.stub_responses(:list_suppressed_destinations, [
                          { suppressed_destination_summaries: [summary("Ada@Example.com")], next_token: "p2" },
                          { suppressed_destination_summaries: [summary("ADA@example.com")] }
                        ])
    assert_raises(Bouncy::UnsafeSnapshot) { Bouncy.release!("ada@example.com", note: "again", actor: "support") }
    assert(@ses.api_requests.none? { |request| request[:operation_name] == :delete_suppressed_destination })
  end

  test "the limits must be positive" do
    [[:sync_max_pages, 0], [:sync_max_entries, -1], [:sync_max_pages, 1.5], [:sync_max_duration, 0], [:sync_max_duration, "1 hour"]].each do |setting, value|
      Bouncy.reset_configuration!
      Bouncy.configuration.scope = "ses:123456789012:us-east-1:account"
      Bouncy.configuration.public_send("#{setting}=", value)
      assert_raises(Bouncy::ConfigurationError, setting.to_s) { Bouncy.configuration.validate! }
    end
  end

  test "a failed or truncated sync keeps a fresh mirror in force; an unverified policy or old age ends it" do
    Bouncy.configuration.adapter = @provider
    @provider.entries = [entry]
    Bouncy.sync!
    assert Bouncy.sync_fresh?

    travel 1.minute
    @provider.on_snapshot = -> { raise Bouncy::ProviderError, "throttled" }
    assert_raises(Bouncy::ProviderError) { Bouncy.sync! }
    assert Bouncy.sync_fresh?, "one failed attempt says nothing about the mirror"
    refute Bouncy.sync_fresh?(Bouncy.last_sync), "the failed summary itself is not fresh"

    travel 1.minute
    @provider.on_snapshot = nil
    @provider.complete = false
    Bouncy.sync!
    assert Bouncy.sync_fresh?, "a truncated read changes nothing about the mirror"

    travel 1.minute
    @provider.complete = true
    @provider.policy_verified = false
    Bouncy.sync!
    refute Bouncy.sync_fresh?, "a sync that found the sending policy unverified stops enforcement at once"

    travel 1.minute # Frozen time: summaries need distinct times, as UUID keys do not order them.
    @provider.policy_verified = true
    Bouncy.sync!
    assert Bouncy.sync_fresh?
    @provider.on_snapshot = -> { raise Bouncy::ProviderError, "throttled" }
    travel 3.hours
    assert_raises(Bouncy::ProviderError) { Bouncy.sync! }
    refute Bouncy.sync_fresh?, "past stale_after the last complete sync no longer counts"
  end

  private

  def pages
    @ses.stub_responses(:list_suppressed_destinations, [
                          { suppressed_destination_summaries: [summary("a@example.com")], next_token: "p2" },
                          { suppressed_destination_summaries: [summary("b@example.com")], next_token: "p3" },
                          { suppressed_destination_summaries: [summary("c@example.com")] }
                        ])
  end

  def list_requests = @ses.api_requests.select { |request| request[:operation_name] == :list_suppressed_destinations }

  def summary(email, reason: "BOUNCE")
    { email_address: email, reason: reason, last_update_time: 1.day.ago }
  end
end
