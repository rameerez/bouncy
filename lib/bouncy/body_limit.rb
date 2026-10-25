# frozen_string_literal: true

module Bouncy
  # Rack middleware that cuts the body of a request to the receiver before Rails reads it.
  #
  # Rails reads a whole chunked body to learn its length, and parses a JSON or form body for
  # its request log, before the route runs. The receiver's own limit then comes too late.
  # SNS posts 256 KB at most. A longer body gets 413 after limit + 1 bytes are read; a shorter
  # one goes on with a plain Content-Length. Every path the router sends to the receiver starts
  # with the path once its repeated slashes are squeezed ("//bouncy/webhooks/ses/",
  # "/bouncy/webhooks/ses.json").
  #
  #   # config/application.rb
  #   config.middleware.insert_before 0, Bouncy::BodyLimit, path: "/bouncy/webhooks/ses"
  class BodyLimit
    DEFAULT_LIMIT = 300.kilobytes

    def initialize(app, path: "/bouncy/webhooks/ses", limit: DEFAULT_LIMIT)
      @app = app
      @path = path.to_s.squeeze("/").chomp("/")
      @limit = limit
      raise ArgumentError, "path must be the receiver's absolute path" unless @path.start_with?("/") && @path.size > 1
      raise ArgumentError, "limit must be a positive number of bytes" unless @limit.is_a?(Integer) && @limit.positive?
    end

    def call(environment)
      return @app.call(environment) unless environment["PATH_INFO"].to_s.squeeze("/").start_with?(@path)

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

    def too_large = [413, { "content-type" => "text/plain", "cache-control" => "no-store" }, [Rack::Utils::HTTP_STATUS_CODES.fetch(413)]]
  end
end
