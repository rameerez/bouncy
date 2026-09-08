# frozen_string_literal: true

require "test_helper"

class ExampleMailer < ActionMailer::Base
  def notice(to:, cc: nil, bcc: nil, envelope: nil)
    mail(from: "sender@example.com", to: to, cc: cc, bcc: bcc, subject: "Private subject", body: "Private body").tap do |message|
      message.smtp_envelope_to = envelope if envelope
    end
  end
end

class InterceptorTest < BouncyTest
  include ActiveJob::TestHelper

  def setup
    super
    ActionMailer::Base.deliveries.clear
    Bouncy.block!("ada@example.com", note: "Hold")
  end

  test "log mode observes recipients without changing delivery" do
    message = ExampleMailer.notice(to: ["Ada <ada@example.com>", "ben@example.com"]).deliver_now
    assert_equal %w[ada@example.com ben@example.com], message.to
    assert_equal 1, ActionMailer::Base.deliveries.size
    event = Bouncy.events.where(kind: "skipped").sole
    assert_equal "log", event.details["mode"]
    refute(event.attributes.values.any? { |value| value.to_s.include?("Private subject") })
  end

  test "drop removes blocked Bcc and preserves allowed envelope subset" do
    Bouncy.configuration.interception = :drop
    message = ExampleMailer.notice(to: "header-only@example.com", bcc: "ada@example.com",
                                   envelope: ["ada@example.com", "actual@example.com"]).deliver_now
    assert_equal ["actual@example.com"], message.smtp_envelope_to
    assert_equal ["header-only@example.com"], message.to
    assert_nil message.bcc
    assert_equal 1, ActionMailer::Base.deliveries.size
  end

  test "all blocked recipients prevent normal delivery" do
    Bouncy.configuration.interception = :drop
    message = ExampleMailer.notice(to: "ada@example.com").deliver_now
    assert_empty ActionMailer::Base.deliveries
    assert_empty message.smtp_envelope_to
    refute message.perform_deliveries
  end

  test "registered interceptor runs on deliver later when the job executes" do
    Bouncy.configuration.interception = :drop
    perform_enqueued_jobs { ExampleMailer.notice(to: ["ada@example.com", "ben@example.com"]).deliver_later }
    assert_equal ["ben@example.com"], ActionMailer::Base.deliveries.sole.smtp_envelope_to
  end

  test "bang delivery is an explicitly unsupported bypass of perform deliveries" do
    Bouncy.configuration.interception = :drop
    error = assert_raises(ArgumentError) { ExampleMailer.notice(to: "ada@example.com").deliver_now! }
    assert_match(/SMTP To address may not be blank/, error.message)
    assert_empty ActionMailer::Base.deliveries
  end

  test "off and execution local bypass leave the message intact" do
    Bouncy.configuration.interception = :off
    assert_equal ["ada@example.com"], ExampleMailer.notice(to: "ada@example.com").deliver_now.to
    Bouncy.configuration.interception = :drop
    Bouncy.unblocked do
      Bouncy.unblocked { assert_equal ["ada@example.com"], ExampleMailer.notice(to: "ada@example.com").deliver_now.to }
      assert_equal ["ada@example.com"], ExampleMailer.notice(to: "ada@example.com").deliver_now.to
    end
    assert_raises(RuntimeError) { Bouncy.unblocked { raise "failed" } }
    assert_nil ActiveSupport::IsolatedExecutionState[:bouncy_unblocked]
  end

  test "failed skip persistence leaves headers and envelope intact" do
    Bouncy.configuration.interception = :drop
    Bouncy::Event.stub(:create!, ->(*) { raise ActiveRecord::ConnectionNotEstablished }) do
      message = ExampleMailer.notice(to: "ada@example.com", envelope: ["ada@example.com"]).deliver_now
      assert_equal ["ada@example.com"], message.to
      assert_equal ["ada@example.com"], message.smtp_envelope_to
      assert message.perform_deliveries
    end
  end

  test "provider enforcement requires a fresh complete sync" do
    Bouncy.release!("ada@example.com", at: :local)
    observe
    Bouncy.configuration.interception = :drop
    assert_equal ["ada@example.com"], ExampleMailer.notice(to: "ada@example.com").deliver_now.to
    Bouncy.sync!
    assert_nil ExampleMailer.notice(to: "ada@example.com").deliver_now.to
    travel 3.hours
    assert_equal ["ada@example.com"], ExampleMailer.notice(to: "ada@example.com").deliver_now.to
  end

  test "allowed messages are untouched and invalid addresses are not turned into policies" do
    message = Mail.new(to: "ben@example.com", from: "sender@example.com", body: "hello")
    original = message.encoded
    Bouncy::Interceptor.delivering_email(message)
    assert_equal original, message.encoded
    message.smtp_envelope_to = ["bad"]
    Bouncy::Interceptor.delivering_email(message)
    assert_equal ["bad"], message.smtp_envelope_to
  end
end
