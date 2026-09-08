# frozen_string_literal: true

module Bouncy
  module Providers
    class SesParser
      RECIPIENT_LIMIT = 1000

      def initialize(configuration)
        @configuration = configuration
      end

      def call(envelope)
        payload = JSON.parse(envelope.fetch("Message"), max_nesting: 20)
        raise MalformedMessage, "Expected SES object" unless payload.is_a?(Hash)

        type = payload["notificationType"] || payload["eventType"]
        section = case type
                  when "Bounce" then "bounce"
                  when "Complaint" then "complaint"
                  when "Delivery" then "delivery"
                  when "DeliveryDelay" then "deliveryDelay"
                  else ""
                  end
        data = payload.fetch(section, {})
        raise MalformedMessage, "Invalid SES event details" unless data.is_a?(Hash)

        recipients = case type
                     when "Bounce" then data.fetch("bouncedRecipients", [])
                     when "Complaint" then data.fetch("complainedRecipients", [])
                     when "Delivery" then @configuration.record_deliveries ? data.fetch("recipients", []) : []
                     when "DeliveryDelay" then data.fetch("delayedRecipients", [])
                     else []
                     end
        raise MalformedMessage, "Invalid SES recipient count" unless recipients.is_a?(Array) && recipients.size <= RECIPIENT_LIMIT

        mail = payload.fetch("mail", {})
        raise MalformedMessage, "Invalid SES mail metadata" unless mail.is_a?(Hash)

        time, fallback = timestamp(data["timestamp"], envelope.fetch("Timestamp"))
        recipients = [nil] if recipients.empty?
        recipients.map do |recipient|
          raw_email = recipient.is_a?(Hash) ? recipient["emailAddress"] : recipient
          email = normalize(raw_email)
          kind, classification = classify(type, data)
          details = { "exact_email" => raw_email.to_s.truncate(254), "timestamp_fallback" => fallback,
                      "certainty" => "candidate", "classification" => classification }
          details["invalid_recipient"] = true if raw_email && !email
          recipientless_kind = %w[reject rendering_failure ignored].include?(kind) && raw_email.nil?
          Observation.new(email: email, kind: email || recipientless_kind ? kind : "ignored",
                          provider_event_id: bounded(data["feedbackId"] || envelope.fetch("MessageId"), 255),
                          message_id: bounded(mail["messageId"], 255), occurred_at: time, details: details,
                          provider_reason: bounded(data["bounceSubType"] || data["complaintFeedbackType"], 255),
                          status_code: recipient.is_a?(Hash) ? bounded(recipient["status"], 255) : nil,
                          diagnostic: recipient.is_a?(Hash) ? bounded(recipient["diagnosticCode"], 1000) : nil)
        end
      rescue JSON::ParserError
        raise MalformedMessage, "Malformed SES payload"
      end

      private

      def normalize(value)
        Identity.normalize(value)
      rescue InvalidAddress
        nil
      end

      def bounded(value, length)
        value&.to_s&.truncate(length)
      end

      def timestamp(value, fallback)
        [Time.iso8601(value || fallback), value.nil?]
      rescue ArgumentError, TypeError
        raise MalformedMessage, "Invalid SES timestamp"
      end

      def classify(type, data)
        case type
        when "Bounce"
          case data["bounceSubType"]
          when "OnAccountSuppressionList" then %w[provider_suppressed account]
          when "Suppressed", "OnTenantSuppressionList", "EmailValidationSuppressed" then ["unknown", data["bounceSubType"]]
          when "UnsubscribedRecipient" then %w[unsubscribe list]
          else
            if data["bounceType"] == "Permanent" && %w[General NoEmail].include?(data["bounceSubType"])
              %w[hard_bounce address]
            elsif %w[Transient Undetermined].include?(data["bounceType"])
              ["soft_bounce", data["bounceSubType"]]
            else
              %w[unknown unrecognized_bounce]
            end
          end
        when "Complaint"
          data["complaintFeedbackType"] == "not-spam" ? %w[ignored not_spam] : %w[complaint candidate]
        when "Delivery" then %w[delivery server_accepted]
        when "DeliveryDelay" then %w[delay retrying]
        when "Reject" then %w[reject message]
        when "Rendering Failure", "RenderingFailure" then %w[rendering_failure message]
        else %w[ignored unsupported_type]
        end
      end
    end
  end
end
