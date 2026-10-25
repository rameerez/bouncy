# frozen_string_literal: true

require "test_helper"
require "support/signed_sns"

# Bouncy::BodyLimit cuts the receiver's request body before the rest of the Rack stack reads
# it. Rails would read a whole chunked body to learn its length, and parse a JSON body for its
# request log, before the route runs.
class BodyLimitTest < BouncyTest
  include SignedSns

  # A request body that counts the bytes read from it.
  class CountingInput < StringIO
    attr_reader :bytes_read

    def read(length = nil, buffer = nil)
      super.tap { |chunk| @bytes_read = @bytes_read.to_i + chunk.to_s.bytesize }
    end
  end

  # Stands in for Rails: reads the whole body, as Rails does for a chunked or JSON request.
  READ_ALL = lambda do |environment|
    body = environment["rack.input"]&.read.to_s
    length = environment["CONTENT_LENGTH"]
    chunked = environment.key?("HTTP_TRANSFER_ENCODING")
    [200, { "content-type" => "text/plain" }, ["#{body.bytesize} #{length} #{chunked}"]]
  end

  def request(path, input, limit: nil, **headers)
    options = { path: "/webhooks/ses" }
    options[:limit] = limit if limit
    # A server passes the request path as it came; Rack::MockRequest would read "//x" as a host.
    environment = Rack::MockRequest.env_for("/", method: "POST", input: input).merge("PATH_INFO" => path, **headers)
    Bouncy::BodyLimit.new(READ_ALL, **options).call(environment)
  end

  test "a body larger than SNS ever sends is refused after limit + 1 bytes, before the app reads it" do
    limit = Bouncy::BodyLimit::DEFAULT_LIMIT
    assert_equal 300 * 1024, limit
    [
      ["/webhooks/ses", { "HTTP_TRANSFER_ENCODING" => "chunked", "CONTENT_TYPE" => "text/plain; charset=UTF-8" }],
      ["/webhooks/ses", { "HTTP_TRANSFER_ENCODING" => "chunked", "CONTENT_TYPE" => "application/json" }],
      ["/webhooks/ses", { "CONTENT_LENGTH" => "10", "CONTENT_TYPE" => "text/plain; charset=UTF-8" }],
      ["//webhooks//ses/", { "HTTP_TRANSFER_ENCODING" => "chunked" }],
      ["/webhooks/ses.json", { "HTTP_TRANSFER_ENCODING" => "chunked" }]
    ].each do |path, headers|
      input = CountingInput.new("x" * (limit * 4))
      status, = request(path, input, **headers)

      assert_equal 413, status, path
      assert_operator input.bytes_read, :<=, limit + 1, "#{path} with #{headers} read #{input.bytes_read} bytes"
    end
  end

  test "a body within the limit goes on whole, with a plain Content-Length" do
    status, _headers, body = request("/webhooks/ses", StringIO.new("x" * 1000), "HTTP_TRANSFER_ENCODING" => "chunked", "CONTENT_LENGTH" => "5")
    assert_equal [200, ["1000 1000 false"]], [status, body]
    status, _headers, body = request("/webhooks/ses", nil)
    assert_equal [200, ["0 0 false"]], [status, body]
  end

  test "other paths, adjacent routes included, are not read, and the limit and the path are configurable" do
    ["/other", "/webhooks/ses-admin", "/webhooks/sesame", "/webhooks/ses/extra", "/webhooks", "/prefix/webhooks/ses"].each do |path|
      input = CountingInput.new("x" * 10)
      status, = request(path, input)
      assert_equal 200, status, path
      assert_equal 10, input.bytes_read, "only the app read #{path}"
    end

    status, = request("/webhooks/ses", StringIO.new("x" * 11), limit: 10)
    assert_equal 413, status
    status, = request("/webhooks/ses", StringIO.new("x" * 10), limit: 10)
    assert_equal 200, status
    assert_raises(ArgumentError) { Bouncy::BodyLimit.new(READ_ALL, limit: 0) }
    assert_raises(ArgumentError) { Bouncy::BodyLimit.new(READ_ALL, limit: "300") }
    assert_raises(ArgumentError) { Bouncy::BodyLimit.new(READ_ALL, path: "/") }
    assert_raises(ArgumentError) { Bouncy::BodyLimit.new(READ_ALL, path: "webhooks/ses") }
  end

  test "an adjacent route gets an oversized body whole and untouched" do
    limit = Bouncy::BodyLimit::DEFAULT_LIMIT
    input = CountingInput.new("x" * (limit * 2))
    seen = nil
    app = lambda do |environment|
      body = environment["rack.input"]
      seen = [body.equal?(input), body.read.bytesize, environment["CONTENT_LENGTH"], environment["HTTP_TRANSFER_ENCODING"]]
      [200, {}, []]
    end
    environment = Rack::MockRequest.env_for("/", method: "POST", input: input).merge("PATH_INFO" => "/webhooks/ses-admin", "CONTENT_LENGTH" => nil,
                                                                                     "HTTP_TRANSFER_ENCODING" => "chunked")
    status, = Bouncy::BodyLimit.new(app, path: "/webhooks/ses").call(environment)
    assert_equal 200, status
    assert_equal [true, limit * 2, nil, "chunked"], seen
    assert_equal limit * 2, input.bytes_read, "only the downstream app read it"
  end

  test "an app mounted under a prefix is limited by its routed path or by its full path" do
    limit = Bouncy::BodyLimit::DEFAULT_LIMIT
    mounts = [["/app", "/webhooks/ses", "/webhooks/ses"], ["/app", "/webhooks/ses", "/app/webhooks/ses"],
              ["/app/", "//webhooks/ses.json", "/app/webhooks/ses"]]
    mounts.each do |script_name, path_info, configured|
      input = CountingInput.new("x" * (limit + 10))
      environment = Rack::MockRequest.env_for("/", method: "POST", input: input).merge("SCRIPT_NAME" => script_name, "PATH_INFO" => path_info)
      status, = Bouncy::BodyLimit.new(READ_ALL, path: configured).call(environment)
      assert_equal 413, status, [script_name, path_info, configured].inspect
      assert_operator input.bytes_read, :<=, limit + 1
    end
    environment = Rack::MockRequest.env_for("/", method: "POST", input: StringIO.new("x" * (limit + 10)))
    status, = Bouncy::BodyLimit.new(READ_ALL, path: "/app/webhooks/ses").call(environment.merge("SCRIPT_NAME" => "/other", "PATH_INFO" => "/webhooks/ses"))
    assert_equal 200, status, "another mount's route is not this receiver"
  end

  test "in front of the mounted engine, a signed notification still reaches the receiver" do
    Bouncy.configuration.adapter = nil
    Bouncy.configuration.ses.region = "us-east-1"
    Bouncy.configuration.ses.topic_arns = [TOPIC]
    stub_request(:get, CERT_URL).to_return(body: CERT.to_pem)
    app = Bouncy::BodyLimit.new(Bouncy::Engine, path: "/webhooks/ses")

    response = Rack::MockRequest.new(app).post("/webhooks/ses", input: signed_envelope, "HTTP_TRANSFER_ENCODING" => "chunked")
    assert_equal 200, response.status
    assert Bouncy.blocked?("ada@example.com")
    assert_equal 413, Rack::MockRequest.new(app).post("/webhooks/ses", input: "x" * (301 * 1024)).status
  end
end
