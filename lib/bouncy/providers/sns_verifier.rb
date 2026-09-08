# frozen_string_literal: true

require "aws-sdk-sns"

module Bouncy
  module Providers
    class SnsVerifier
      BODY_LIMIT = 2 * 1024 * 1024

      class BoundedVerifier < Aws::SNS::MessageVerifier
        private

        def pem(uri)
          @cached_pems.shift if @cached_pems.size >= 32 && !@cached_pems.key?(uri.to_s)
          super
        end

        def https_get(uri)
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

      def initialize(configuration)
        @configuration = configuration
        @verifier = BoundedVerifier.new
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
        @mutex.synchronize { @verifier.authenticate!(raw_body) }
        envelope
      rescue JSON::ParserError, URI::InvalidURIError
        raise MalformedMessage, "Malformed SNS envelope"
      rescue Aws::SNS::MessageVerifier::VerificationError, OpenSSL::OpenSSLError
        raise AuthenticationError, "SNS signature could not be verified"
      end

      private

      def authorize!(envelope)
        topic = envelope.fetch("TopicArn")
        settings = @configuration.ses
        parts = topic.split(":")
        unless settings.topic_arns.is_a?(Array) && settings.topic_arns.include?(topic) && parts.size == 6 && parts[0] == "arn" && parts[2] == "sns" &&
               parts[3] == settings.region && @configuration.scope == "ses:#{parts[4]}:#{parts[3]}:account"
          raise AuthenticationError, "SNS topic is not authorized"
        end

        suffix = { "aws" => "amazonaws.com", "aws-us-gov" => "amazonaws.com", "aws-cn" => "amazonaws.com.cn" }[parts[1]]
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
