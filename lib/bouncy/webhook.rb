# frozen_string_literal: true

module Bouncy
  class Webhook
    BODY_LIMIT = 2 * 1024 * 1024

    def call(environment)
      return response(405) unless environment["REQUEST_METHOD"] == "POST"

      body = environment.fetch("rack.input").read(BODY_LIMIT + 1)
      return response(413) if body.bytesize > BODY_LIMIT

      adapter = Bouncy.adapter
      envelope = adapter.authenticate(raw_body: body, headers: environment)
      unless adapter.control(envelope)
        raise MalformedMessage, "Unsupported SNS control type" unless envelope["Type"] == "Notification"

        adapter.parse(envelope).each { |event| Ingestor.new.call(event) }
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

    def response(status)
      [status, { "content-type" => "text/plain", "cache-control" => "no-store" }, [Rack::Utils::HTTP_STATUS_CODES.fetch(status)]]
    end
  end
end
