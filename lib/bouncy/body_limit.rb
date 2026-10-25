# frozen_string_literal: true

module Bouncy
  # Rack middleware that cuts the body of a request to the receiver before Rails reads it.
  #
  # Rails reads a whole chunked body to learn its length, and parses a JSON or form body for
  # its request log, before the route runs. The receiver's own limit then comes too late.
  # SNS posts 256 KB at most. A longer body gets 413 after limit + 1 bytes are read; a shorter
  # one goes on with a plain Content-Length.
  #
  # The limit applies to the paths the router sends to the receiver: the path itself, with
  # repeated slashes squeezed, an optional trailing slash and an optional format suffix
  # ("//bouncy/webhooks/ses/", "/bouncy/webhooks/ses.json"). It is compared with PATH_INFO and
  # with SCRIPT_NAME + PATH_INFO, so it also holds when the app is mounted under a prefix. An
  # adjacent route such as "/bouncy/webhooks/ses-admin" is not limited.
  #
  #   # config/application.rb
  #   config.middleware.insert_before 0, Bouncy::BodyLimit, path: "/bouncy/webhooks/ses"
  class BodyLimit
    DEFAULT_LIMIT = 300.kilobytes

    def initialize(app, path: "/bouncy/webhooks/ses", limit: DEFAULT_LIMIT)
      @app = app
      normalized = path.to_s.squeeze("/").chomp("/")
      raise ArgumentError, "path must be the receiver's absolute path" unless normalized.start_with?("/") && normalized.size > 1
      raise ArgumentError, "limit must be a positive number of bytes" unless limit.is_a?(Integer) && limit.positive?

      @limit = limit
      @route = %r{\A#{Regexp.escape(normalized)}(?:\.[^/.]+)?/?\z}
    end

    def call(environment)
      return @app.call(environment) unless receiver?(environment)

      input = environment["rack.input"]
      input.rewind if input.respond_to?(:rewind)
      body = input&.read(@limit + 1).to_s
      return too_large if body.bytesize > @limit

      environment["rack.input"] = StringIO.new(body)
      environment["CONTENT_LENGTH"] = body.bytesize.to_s
      environment.delete("HTTP_TRANSFER_ENCODING")
      @app.call(environment)
    end

    private

    def receiver?(environment)
      path = environment["PATH_INFO"].to_s
      [path, environment["SCRIPT_NAME"].to_s + path].any? { |candidate| candidate.squeeze("/").match?(@route) }
    end

    def too_large = [413, { "content-type" => "text/plain", "cache-control" => "no-store" }, [Rack::Utils::HTTP_STATUS_CODES.fetch(413)]]
  end
end
