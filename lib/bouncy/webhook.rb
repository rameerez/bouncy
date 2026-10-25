# frozen_string_literal: true

module Bouncy
  class Webhook
    BODY_LIMIT = 2 * 1024 * 1024
    METHODS = %w[GET HEAD PUT PATCH DELETE OPTIONS TRACE CONNECT].freeze
    INVALID = "<invalid>"
    TOPIC_ARN = /\Aarn:aws[a-z-]*:sns:[a-z]{2}(?:-[a-z]+)+-\d+:\d{12}:[A-Za-z0-9_-]{1,256}\z/

    def call(environment)
      method = environment["REQUEST_METHOD"]
      unless method == "POST"
        shown = METHODS.include?(method) ? method : INVALID
        return refuse(405, "method #{shown} is not POST")
      end

      # An unconfigured receiver answers 503 so the provider retries later instead of
      # treating the endpoint as broken or, worse, as having accepted the notification.
      Bouncy.configuration.validate!
      body = environment.fetch("rack.input").read(BODY_LIMIT + 1).to_s
      return refuse(400, "empty body") if body.empty?

      return refuse(413, "body over #{BODY_LIMIT} bytes") if body.bytesize > BODY_LIMIT

      adapter = Bouncy.adapter
      envelope = adapter.authenticate(raw_body: body, headers: environment)
      unless adapter.control(envelope)
        raise MalformedMessage, "Unsupported SNS control type" unless envelope["Type"] == "Notification"

        adapter.parse(envelope).each { |event| Ingestor.new.call(event) }
        return response(503) unless notified?(adapter, envelope)
      end
      response(200)
    rescue AuthenticationError => e
      refuse(401, e.message, body)
    rescue MalformedMessage => e
      refuse(400, e.message, body)
    rescue ProviderError, ConfigurationError => e
      refuse(503, e.message, body)
    rescue ActiveRecord::ActiveRecordError => e
      # A database message can quote a statement and its values, so only the class is logged.
      refuse(503, e.class.name, body)
    end

    private

    # One warning per refused message: how a dead subscription is found in production. It names
    # the reason and where the message claims to come from. The message is not authenticated, so
    # a topic is logged only when it has the strict SNS ARN syntax and a SubscribeURL host only
    # when it passes the SNS host check; anything else is written as <invalid>. No raw field of
    # the body is ever copied into the log.
    def refuse(status, reason, body = nil)
      Rails.logger&.warn("[bouncy] refused an SNS message (#{status}): #{reason}#{origin(body)}")
      response(status)
    end

    def origin(body)
      envelope = JSON.parse(body.to_s, max_nesting: 30)
      return "" unless envelope.is_a?(Hash)

      parts = []
      topic = envelope["TopicArn"] if envelope["TopicArn"].is_a?(String) && envelope["TopicArn"].match?(TOPIC_ARN)
      parts << "topic #{topic || INVALID}" if envelope.key?("TopicArn")
      if envelope["Type"] == "SubscriptionConfirmation" && envelope.key?("SubscribeURL")
        uri = Providers::Ses.subscribe_uri(envelope, Bouncy.configuration.ses.region) if topic
        parts << "SubscribeURL host #{uri&.host || INVALID}"
      end
      parts.map { |part| "; #{part}" }.join
    rescue JSON::ParserError
      ""
    end

    # config.on_notification runs after the state committed, outside Bouncy's locks, and before
    # the answer. A failure answers 503, so SNS delivers the notification again; the repeat
    # deduplicates and calls the hook again.
    def notified?(adapter, envelope)
      return true unless adapter.respond_to?(:notification)

      Bouncy.configuration.on_notification.call(adapter.notification(envelope))
      true
    rescue StandardError => e
      ActiveSupport::Notifications.instrument("hook_error.bouncy", hook: :on_notification, error_class: e.class.name)
      Rails.logger&.error("[bouncy] config.on_notification raised #{e.class.name}; answering 503 so SNS retries")
      false
    end

    def response(status)
      [status, { "content-type" => "text/plain", "cache-control" => "no-store" }, [Rack::Utils::HTTP_STATUS_CODES.fetch(status)]]
    end
  end
end
