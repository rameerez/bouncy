# frozen_string_literal: true

module Bouncy
  class Webhook
    BODY_LIMIT = 2 * 1024 * 1024

    def call(environment)
      return response(405) unless environment["REQUEST_METHOD"] == "POST"

      # An unconfigured receiver answers 503 so the provider retries later instead of
      # treating the endpoint as broken or, worse, as having accepted the notification.
      Bouncy.configuration.validate!
      body = environment.fetch("rack.input").read(BODY_LIMIT + 1).to_s
      return response(400) if body.empty?

      return response(413) if body.bytesize > BODY_LIMIT

      adapter = Bouncy.adapter
      envelope = adapter.authenticate(raw_body: body, headers: environment)
      unless adapter.control(envelope)
        raise MalformedMessage, "Unsupported SNS control type" unless envelope["Type"] == "Notification"

        adapter.parse(envelope).each { |event| Ingestor.new.call(event) }
        return response(503) unless notified?(adapter, envelope)
      end
      response(200)
    rescue AuthenticationError
      response(401)
    rescue MalformedMessage
      response(400)
    rescue ProviderError, ConfigurationError, ActiveRecord::ActiveRecordError
      response(503)
    end

    private

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
