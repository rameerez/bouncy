# frozen_string_literal: true

require "aws-sdk-sns"

module Bouncy
  module Providers
    class SnsVerifier
      BODY_LIMIT = 2 * 1024 * 1024

      # Signing certificates, shared by every receiver in the process: each request builds a new
      # adapter, and an app that subscribes to Send and Delivery events gets one SNS message per
      # mail. At most 16 certificate URLs, each kept for an hour. Only a certificate that the
      # allowlisted, bounded download returned is kept.
      #
      # Unauthenticated requests share a small download concurrency cap. Wait briefly for a
      # slot so a burst of fast 404s does not exclude a genuine new certificate. Failed URLs are
      # cached briefly. Sustained saturation can still exhaust the wait and SNS's retry window;
      # operators need a monitored dead-letter queue for durable recovery.
      class CertificateCache
        Entry = Data.define(:pem, :fetched_at)
        Failure = Data.define(:error, :message, :failed_at)
        REMEMBERED = [ProviderError, AuthenticationError, Aws::SNS::MessageVerifier::VerificationError].freeze

        def initialize(size:, ttl:, failure_ttl: 10, failures: 64, concurrency: 2, wait: 2)
          @size = size
          @ttl = ttl
          @failure_ttl = failure_ttl
          @failure_size = failures
          @concurrency = concurrency
          @wait = wait
          @entries = {}
          @failures = {}
          @in_flight = 0
          @in_flight_urls = Hash.new(0)
          @mutex = Mutex.new
          @available = ConditionVariable.new
        end

        # Check again after waiting: another request may have fetched the same certificate.
        def fetch(url)
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @wait
          entry = @mutex.synchronize do
            loop do
              cached = @entries[url]
              break cached if cached && Time.now - cached.fetched_at < @ttl

              failure = @failures[url]
              raise failure.error, failure.message if failure && Time.now - failure.failed_at < @failure_ttl

              if @in_flight < @concurrency
                @in_flight += 1
                @in_flight_urls[url] += 1
                break nil
              end
              remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
              raise ProviderError, "Too many SNS certificate downloads in progress" if remaining <= 0

              @available.wait(@mutex, remaining)
            end
          end
          return entry.pem if entry

          begin
            pem = yield
            @mutex.synchronize do
              @failures.delete(url)
              @entries.delete(url)
              @entries[url] = Entry.new(pem: pem, fetched_at: Time.now)
              @entries.shift while @entries.size > @size
            end
            pem
          rescue *REMEMBERED => e
            @mutex.synchronize do
              @failures.delete(url)
              @failures[url] = Failure.new(error: e.class, message: e.message, failed_at: Time.now)
              @failures.shift while @failures.size > @failure_size
            end
            raise
          ensure
            @mutex.synchronize do
              @in_flight -= 1
              @in_flight_urls[url] -= 1
              @in_flight_urls.delete(url) if @in_flight_urls[url].zero?
              @available.broadcast
            end
          end
        end

        # Do not refetch a recently fetched certificate for every forged signature.
        def forget(url, after:)
          @mutex.synchronize do
            entry = @entries[url]
            next false unless entry && Time.now - entry.fetched_at >= after

            @entries.delete(url)
            true
          end
        end

        def retryable?(url, after:)
          @mutex.synchronize do
            entry = @entries[url]
            @in_flight_urls.key?(url) || (entry && Time.now - entry.fetched_at < after)
          end
        end

        def size = @mutex.synchronize { @entries.size }
        def clear = @mutex.synchronize { [@entries, @failures].each(&:clear) }
      end

      CERTIFICATES = CertificateCache.new(size: 16, ttl: 3600)
      # A cached certificate older than this is fetched again, once, when a signature fails.
      REFETCH_AFTER = 5

      class BoundedVerifier < Aws::SNS::MessageVerifier
        private

        # The SDK's download_pem checks the URL and the PEM framing, and calls the bounded
        # https_get below. A certificate is cached only once it parses and carries the RSA key
        # that SNS signs with; any other body is refused and never kept, so the next request
        # fetches again at once.
        def pem(uri) = CERTIFICATES.fetch(uri.to_s) { usable(download_pem(uri)) }

        def usable(pem)
          key = OpenSSL::X509::Certificate.new(pem).public_key
          raise VerificationError, "The SNS signing certificate has no RSA key" unless key.is_a?(OpenSSL::PKey::RSA)

          pem
        rescue OpenSSL::X509::CertificateError, OpenSSL::PKey::PKeyError
          raise VerificationError, "The SNS signing certificate does not parse"
        end

        def https_get(uri, _failed_attempts = 0)
          body = +""
          Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 3, read_timeout: 5,
                                              verify_mode: OpenSSL::SSL::VERIFY_PEER, max_retries: 0) do |http|
            http.request(Net::HTTP::Get.new(uri.request_uri)) do |response|
              raise ProviderError, "SNS certificate fetch failed" unless response.code == "200"

              response.read_body do |chunk|
                body << chunk
                raise AuthenticationError, "SNS certificate exceeds limit" if body.bytesize > 64 * 1024
              end
            end
          end
          body
        rescue Timeout::Error, SocketError, IOError, SystemCallError, OpenSSL::SSL::SSLError
          raise ProviderError, "SNS certificate transport unavailable"
        end
      end

      # The bounded verifier overrides two private SDK methods. Refuse to run against an SDK that
      # no longer has them rather than silently fetching certificates without limits.
      HOOKS = %i[pem https_get].freeze

      def initialize(configuration)
        @configuration = configuration
        unless HOOKS.all? { |hook| Aws::SNS::MessageVerifier.private_method_defined?(hook) }
          raise ConfigurationError, "aws-sdk-sns #{Aws::SNS::GEM_VERSION} changed its certificate download internals; " \
                                    "pin aws-sdk-sns to a release tested with this version of bouncy"
        end

        @verifier = configuration.ses.sns_message_verifier || BoundedVerifier.new
        @mutex = Mutex.new
      end

      def call(raw_body)
        envelope = JSON.parse(raw_body, max_nesting: 30)
        raise MalformedMessage, "Expected an SNS object" unless envelope.is_a?(Hash)
        # The SDK supports Lambda aliases by rewriting them. This HTTP receiver
        # must not allow an unvalidated alias to replace the checked certificate URL.
        raise MalformedMessage, "Lambda SNS aliases are not supported" if envelope.key?("SigningCertUrl")

        fields = %w[Type Message MessageId Timestamp TopicArn Signature SignatureVersion SigningCertURL]
        fields += %w[Token SubscribeURL] if %w[SubscriptionConfirmation UnsubscribeConfirmation].include?(envelope["Type"])
        raise MalformedMessage, "Missing SNS fields" unless fields.all? { |key| envelope[key].is_a?(String) && !envelope[key].empty? }
        unless (Aws::SNS::MessageVerifier::SIGNABLE_KEYS & envelope.keys).all? { |key| envelope[key].is_a?(String) }
          raise MalformedMessage, "SNS signable fields must be strings"
        end

        raise AuthenticationError, "SNS signature could not be verified" unless %w[1 2].include?(envelope["SignatureVersion"])

        authorize!(envelope)
        verify(raw_body, envelope.fetch("SigningCertURL"))
        envelope
      rescue JSON::ParserError, URI::InvalidURIError
        raise MalformedMessage, "Malformed SNS envelope"
      rescue Aws::SNS::MessageVerifier::VerificationError, OpenSSL::OpenSSLError
        raise AuthenticationError, "SNS signature could not be verified"
      end

      private

      # A newly cached certificate may have rotated at the same URL. Defer verification with
      # a retryable response until the short refetch interval passes, then fetch and retry once.
      def verify(raw_body, url)
        @mutex.synchronize { @verifier.authenticate!(raw_body) }
      rescue Aws::SNS::MessageVerifier::VerificationError, OpenSSL::OpenSSLError
        raise unless @verifier.is_a?(BoundedVerifier)

        unless CERTIFICATES.forget(url, after: REFETCH_AFTER)
          raise ProviderError, "SNS certificate recheck is temporarily deferred" if CERTIFICATES.retryable?(url, after: REFETCH_AFTER)

          raise
        end

        @mutex.synchronize { @verifier.authenticate!(raw_body) }
      end

      def authorize!(envelope)
        topic = envelope.fetch("TopicArn")
        settings = @configuration.ses
        parts = topic.split(":")
        unless settings.topic_arns.is_a?(Array) && settings.topic_arns.include?(topic) && parts.size == 6 && parts[0] == "arn" && parts[2] == "sns" &&
               parts[3] == settings.region && @configuration.scope == "ses:#{parts[4]}:#{parts[3]}:account"
          raise AuthenticationError, "SNS topic is not authorized"
        end

        suffix = Ses::SNS_DOMAINS[parts[1]]
        uri = URI.parse(envelope.fetch("SigningCertURL"))
        unless suffix && uri.scheme == "https" && uri.host == "sns.#{settings.region}.#{suffix}" &&
               uri.port == 443 && !uri.userinfo && !uri.query && !uri.fragment &&
               uri.path.match?(%r{\A/SimpleNotificationService-[A-Za-z0-9_-]+\.pem\z})
          raise AuthenticationError, "SNS certificate URL is not authorized"
        end
      end
    end
  end
end
