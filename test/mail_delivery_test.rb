# frozen_string_literal: true

require "test_helper"

class DeliveryMailer < ActionMailer::Base
  default from: "sender@example.com"

  def notice(to:, cc: nil, bcc: nil, envelope: nil, **headers)
    mail(to: to, cc: cc, bcc: bcc, subject: "Notice", body: "Hello", **headers).tap do |message|
      message.smtp_envelope_to = envelope if envelope
    end
  end
end

# Mailers whose own before_deliver callback changes the recipients.
class LateRecipientMailer < DeliveryMailer
  before_deliver { message.bcc = ["dan@example.com"] }
end

class ReplacingMailer < DeliveryMailer
  before_deliver { message.to = [params.fetch(:replacement)] }
end

# A Mail interceptor registered after Bouncy's, which rewrites every recipient.
module RewritingInterceptor
  mattr_accessor :replacement

  def self.delivering_email(message)
    message.to = [replacement] if replacement
  end
end
Mail.register_interceptor(RewritingInterceptor)

# Every mail of every mailer goes through Bouncy: it names the SES configuration set when one
# is configured, the blocked addresses leave To, Cc, Bcc and the SMTP envelope with the other
# entries kept as written, and a mail with no recipient left is sent by no delivery method.
class MailDeliveryTest < BouncyTest
  include ActiveJob::TestHelper

  HEADER = Bouncy::Interceptor::CONFIGURATION_SET_HEADER

  def setup
    super
    ActionMailer::Base.deliveries.clear
    Bouncy.configuration.interception = :drop
  end

  def sets_of(mail) = mail.header.fields.select { |field| field.name == HEADER }.map(&:value)

  def deliver_four_ways(&build)
    perform_enqueued_jobs do
      build.call.deliver_now
      build.call.deliver_now!
      build.call.deliver_later
      build.call.deliver_later!
    end
  end

  test "every mail names the configuration set when one is configured, Action Mailer or Mail alone" do
    Bouncy.configuration.ses.configuration_set = "transactional"
    DeliveryMailer.notice(to: "ana@example.com").deliver_now
    Mail.new(from: "sender@example.com", to: "ana@example.com", body: "Hello") { delivery_method :test }.deliver
    DeliveryMailer.notice(to: "ana@example.com").deliver_now!

    assert_equal 3, ActionMailer::Base.deliveries.size
    ActionMailer::Base.deliveries.each { |mail| assert_equal ["transactional"], sets_of(mail) }
  end

  test "without a configuration set, or with a blank one, no header is added" do
    DeliveryMailer.notice(to: "ana@example.com").deliver_now
    Bouncy.configuration.ses.configuration_set = ""
    DeliveryMailer.notice(to: "ana@example.com").deliver_now
    assert(ActionMailer::Base.deliveries.all? { |mail| sets_of(mail).empty? })
  end

  test "a mail that names its own configuration set keeps it, once" do
    Bouncy.configuration.ses.configuration_set = "transactional"
    mail = DeliveryMailer.notice(to: "ana@example.com", HEADER => "its-own-set").deliver_now
    assert_equal ["its-own-set"], sets_of(mail)
  end

  test "the configuration set does not depend on the interception mode or on Bouncy being configured" do
    Bouncy.configuration.ses.configuration_set = "transactional"
    Bouncy.configuration.interception = :off
    DeliveryMailer.notice(to: "ana@example.com").deliver_now
    Bouncy.configuration.interception = :drop
    Bouncy.unblocked { DeliveryMailer.notice(to: "ana@example.com").deliver_now }
    Bouncy.configuration.scope = nil
    DeliveryMailer.notice(to: "ana@example.com").deliver_now

    assert_equal([["transactional"]] * 3, ActionMailer::Base.deliveries.map { |mail| sets_of(mail) })
  end

  test "with interception off or Bouncy unconfigured, a delivery reads nothing from the database" do
    Bouncy.block!("ana@example.com", note: "Hold")
    Bouncy.configuration.interception = :off
    assert_equal(0, queries { DeliveryMailer.notice(to: "ana@example.com", cc: "bea@example.com").deliver_now })
    Bouncy.configuration.interception = :drop
    Bouncy.configuration.scope = nil
    assert_equal(0, queries { DeliveryMailer.notice(to: "ana@example.com").deliver_now! })
    assert_equal [["ana@example.com"]] * 2, ActionMailer::Base.deliveries.map(&:to)
  end

  test "the blocked addresses leave To, Cc and Bcc, the display names stay, and the others still get the mail" do
    Bouncy.block!("bea@example.com", note: "Hold")
    Bouncy.block!("dan@example.com", note: "Hold")

    DeliveryMailer.notice(to: "Ana Example <ana@example.com>, Bea Example <bea@example.com>, \"Doe, Jo\" <jo@example.com>",
                          cc: "BEA@example.com, Cleo <cleo@example.com>", bcc: "dan@example.com").deliver_now!

    mail = ActionMailer::Base.deliveries.sole
    assert_equal ["Ana Example <ana@example.com>", "\"Doe, Jo\" <jo@example.com>"], mail[:to].formatted, "the display names stay"
    assert_equal ["Cleo <cleo@example.com>"], mail[:cc].formatted
    assert_nil mail[:bcc]
    assert_equal %w[ana@example.com jo@example.com cleo@example.com], mail.smtp_envelope_to
    assert_equal %w[bea@example.com dan@example.com], Bouncy.events.where(kind: "skipped").pluck(:email).sort
  end

  test "an explicit SMTP envelope loses its blocked addresses too, written with a display name or in another case" do
    Bouncy.block!("bea@example.com", note: "Hold")
    Bouncy.block!("cleo@example.com", note: "Hold")
    envelope = ["ana@example.com", "Ana Two <ana.two@example.com>", "bea@example.com", "Bea <BEA@Example.com>", "Cleo <cleo@example.com>"]

    DeliveryMailer.notice(to: "ana@example.com", envelope: envelope).deliver_now

    assert_equal ["ana@example.com", "Ana Two <ana.two@example.com>"], ActionMailer::Base.deliveries.sole.smtp_envelope_to
  end

  test "deliver_now, deliver_now!, deliver_later and deliver_later! all send nothing when no recipient is left" do
    Bouncy.block!("ana@example.com", note: "Hold")

    deliver_four_ways { DeliveryMailer.notice(to: "Ana <ana@example.com>") }
    assert_empty ActionMailer::Base.deliveries
    assert_equal 4, Bouncy.events.where(kind: "skipped").count

    deliver_four_ways { DeliveryMailer.notice(to: "Ana <ana@example.com>", cc: "bea@example.com") }
    assert_equal [["bea@example.com"]] * 4, ActionMailer::Base.deliveries.map(&:smtp_envelope_to)
  end

  test "a wholly blocked SMTP envelope sends nothing by any of the four delivery methods" do
    Bouncy.block!("bea@example.com", note: "Hold")

    deliver_four_ways { DeliveryMailer.notice(to: "ana@example.com", envelope: ["Bea <BEA@example.com>"]) }

    assert_empty ActionMailer::Base.deliveries, "To still names ana@example.com, but the envelope is what the transport sends to"
  end

  test "log mode halts nothing, bang methods included, and records one skip per address" do
    Bouncy.block!("ana@example.com", note: "Hold")
    Bouncy.configuration.interception = :log

    deliver_four_ways { DeliveryMailer.notice(to: "ana@example.com") }

    assert_equal [["ana@example.com"]] * 4, ActionMailer::Base.deliveries.map(&:to)
    assert_equal 4, Bouncy.events.where(kind: "skipped").count, "the callback and the interceptor do not both record a mail"
  end

  test "a recipient that a later callback adds is checked when Mail delivers" do
    Bouncy.block!("dan@example.com", note: "Hold")

    LateRecipientMailer.notice(to: "ana@example.com").deliver_now

    mail = ActionMailer::Base.deliveries.sole
    assert_nil mail.bcc
    assert_equal ["ana@example.com"], mail.smtp_envelope_to
  end

  test "a host callback that replaces an allowed recipient with a blocked one reaches no transport" do
    Bouncy.block!("dan@example.com", note: "Hold")

    deliver_four_ways { ReplacingMailer.with(replacement: "Dan <dan@example.com>").notice(to: "ana@example.com") }

    assert_empty ActionMailer::Base.deliveries, "no delivery method received an empty envelope"
    assert_equal 4, Bouncy.events.where(kind: "skipped", email: "dan@example.com").count
  end

  test "a host callback that rewrites a blocked recipient to an allowed one sends to the allowed one" do
    Bouncy.block!("dan@example.com", note: "Hold")

    deliver_four_ways { ReplacingMailer.with(replacement: "ana@example.com").notice(to: "dan@example.com") }

    assert_equal [["ana@example.com"]] * 4, ActionMailer::Base.deliveries.map(&:smtp_envelope_to), "Bouncy decides on what the transport gets"
    assert_empty Bouncy.events.where(kind: "skipped")
  end

  test "an interceptor that runs after Bouncy's cannot slip a blocked recipient past it" do
    Bouncy.block!("dan@example.com", note: "Hold")
    RewritingInterceptor.replacement = "dan@example.com"

    DeliveryMailer.notice(to: "ana@example.com").deliver_now!
    Mail.new(from: "sender@example.com", to: "ana@example.com", body: "Hello") { delivery_method :test }.deliver

    assert_empty ActionMailer::Base.deliveries
  ensure
    RewritingInterceptor.replacement = nil
  end

  test "a message delivered once is judged again at each delivery: bypass, mode and scope" do
    message = DeliveryMailer.notice(to: "ana@example.com").message
    message.deliver
    assert_instance_of Bouncy::Interceptor::Gate, message.delivery_method
    Bouncy.block!("ana@example.com", note: "Hold")

    Bouncy.unblocked { message.deliver }
    Bouncy.configuration.interception = :off
    message.deliver
    Bouncy.configuration.interception = :drop
    Bouncy.configuration.scope = nil
    message.deliver
    Bouncy.configuration.scope = "ses:123456789012:us-east-1:account"
    assert_equal [["ana@example.com"]] * 4, ActionMailer::Base.deliveries.map(&:smtp_envelope_to)

    message.deliver
    assert_equal 4, ActionMailer::Base.deliveries.size, "back in :drop mode the gate drops it"
  end

  test "the gate keeps the transport's settings and methods visible" do
    mail = DeliveryMailer.notice(to: "ana@example.com").deliver_now
    gate = mail.delivery_method
    assert_instance_of Bouncy::Interceptor::Gate, gate
    assert_instance_of Mail::TestMailer, gate.transport
    assert_equal gate.transport.settings, gate.settings
    assert_respond_to gate, :deliver!
    assert_raises(NoMethodError) { gate.no_such_method }
    DeliveryMailer.notice(to: "ana@example.com").message.tap { |message| 2.times { message.deliver } }
    assert_equal 3, ActionMailer::Base.deliveries.size, "a second delivery of one message wraps nothing twice"
  end

  private

  def queries(&)
    count = 0
    counter = ->(*, payload) { count += 1 unless %w[SCHEMA TRANSACTION].include?(payload[:name]) }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record", &)
    count
  end
end
