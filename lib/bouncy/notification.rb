# frozen_string_literal: true

module Bouncy
  # One SES notification, as config.on_notification receives it: every event type SES
  # publishes to the topic, Send and Delivery included, after the receiver committed what it
  # records from it.
  #
  #   config.on_notification = lambda do |notification|
  #     notification.type        # => "Delivery"
  #     notification.message_id  # => the SES message id of the mail
  #     notification.recipients  # => ["ada@example.com"]
  #     notification.occurred_at # => the time SES gives for this event
  #     notification.tags        # => { "order" => ["42"] }
  #     notification.raw         # => the SES JSON object, as a Hash
  #   end
  #
  # SNS repeats and reorders notifications, so the hook must be safe to run again and in any
  # order.
  class Notification
    # The SES object that holds an event's own details, where it is not the type in camelCase.
    SECTIONS = { "Rendering Failure" => "failure", "RenderingFailure" => "failure" }.freeze

    attr_reader :raw

    def initialize(raw, sns_timestamp: nil)
      @raw = raw
      @sns_timestamp = sns_timestamp
    end

    # The SES event type as SES names it: "Send", "Delivery", "Bounce", "Complaint", ...
    def type = raw["eventType"] || raw["notificationType"]

    def message_id = mail["messageId"]

    # The SES message tags of the mail: each name maps to an array of values.
    def tags = mail["tags"].is_a?(Hash) ? mail["tags"] : {}

    # The addresses this event is about, exactly as SES spells them: the bounced, complained,
    # delivered or delayed recipients, or the mail's destination for other events.
    def recipients
      values = case type
               when "Bounce" then section["bouncedRecipients"]
               when "Complaint" then section["complainedRecipients"]
               when "Delivery" then section["recipients"]
               when "DeliveryDelay" then section["delayedRecipients"]
               else mail["destination"]
               end
      Array(values).filter_map do |recipient|
        address = recipient.is_a?(Hash) ? recipient["emailAddress"] : recipient
        address if address.is_a?(String)
      end
    end

    # The time of this event: its own timestamp, else the mail's, else the time SNS published it.
    def occurred_at
      [section["timestamp"], mail["timestamp"], @sns_timestamp].each do |value|
        return Time.iso8601(value) if value.is_a?(String)
      rescue ArgumentError
        next
      end
      nil
    end

    private

    def mail = object(raw["mail"])
    def section = object(raw[SECTIONS.fetch(type.to_s) { type.to_s.sub(/\A./, &:downcase) }])
    def object(value) = value.is_a?(Hash) ? value : {}
  end
end
