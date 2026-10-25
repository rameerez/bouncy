# frozen_string_literal: true

require "aws-sdk-sns"

module Bouncy
  module Providers
    class SnsVerifier
      BODY_LIMIT = 2 * 1024 * 1024

      # Signing certificates, shared by every receiver in the process: each request builds a new
      # adapter, and an app that subscribes to Send and Delivery events gets one SNS message per
      # mail. At most 16 certificate URLs, each kept for an hour. Only a certificate that the
      # allowlisted, bounded download returned is kept; a failed download keeps nothing.
      class CertificateCache
        Entry = Data.define(:pem, :fetched_at)

        def initialize(size:, ttl:)
          @size = size
          @ttl = ttl
          @entries = {}
          @mutex = Mutex.new
        end

        # The download runs outside the lock, so one slow fetch does not stop other requests.
        def fetch(url)
          entry = @mutex.synchronize { @entries[url] }
          return entry.pem if entry && Time.now - entry.fetched_at < @ttl

          pem = yield
          @mutex.synchronize do
            @entries.delete(url)
            @entries[url] = Entry.new(pem: pem, fetched_at: Time.now)
            @entries.shift while @entries.size > @size
          end
          pem
        end

        # Drops a certificate that failed a verification, so the next one fetches it again. A
        # certificate fetched less than `after` seconds ago stays: a stream of forged messages
        # must not turn into a stream of downloads.
        def forget(url, after:)
          @mutex.synchronize do
            entry = @entries[url]
            next false unless entry && Time.now - entry.fetched_at >= after

            @entries.delete(url)
            true
          end
        end

        def size = @mutex.synchronize { @entries.size }
        def clear = @mutex.synchronize { @entries.clear }
      end

      CERTIFICATES = CertificateCache.new(size: 16, ttl: 3600)
      # A cached certificate older than this is fetched again, once, when a signature fails.
      REFETCH_AFTER = 60

      class BoundedVerifier < Aws::SNS::MessageVerifier
        private

        # The SDK's download_pem checks the URL and the PEM format, and calls the bounded
        # https_get below.
        def pem(uri) = CERTIFICATES.fetch(uri.to_s) { download_pem(uri) }

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

        authorize!(envelope)
        verify(raw_body, envelope.fetch("SigningCertURL"))
        envelope
      rescue JSON::ParserError, URI::InvalidURIError
        raise MalformedMessage, "Malformed SNS envelope"
      rescue Aws::SNS::MessageVerifier::VerificationError, OpenSSL::OpenSSLError
        raise AuthenticationError, "SNS signature could not be verified"
      end

      private

      # A certificate that SNS rotated at the same URL fails once from the cache; it is fetched
      # again, once, and the message is checked with the new one.
      def verify(raw_body, url)
        @mutex.synchronize { @verifier.authenticate!(raw_body) }
      rescue Aws::SNS::MessageVerifier::VerificationError, OpenSSL::OpenSSLError
        raise unless @verifier.is_a?(BoundedVerifier) && CERTIFICATES.forget(url, after: REFETCH_AFTER)

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
