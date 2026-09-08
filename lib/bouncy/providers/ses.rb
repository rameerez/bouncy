# frozen_string_literal: true

module Bouncy
  module Providers
    class Ses < Base
      def initialize(configuration = Bouncy.configuration)
        super()
        @configuration = configuration
        @settings = configuration.ses
      end

      def snapshot
        started_at = Time.current
        policy = policy_check
        entries = []
        tokens = []
        token = nil
        loop do
          response = request { client.list_suppressed_destinations(page_size: 1000, next_token: token) }
          response.suppressed_destination_summaries.each do |row|
            Identity.normalize(row.email_address)
            entries << Entry.new(email: row.email_address, reason: reason(row.reason), updated_at: row.last_update_time)
          end
          token = response.next_token
          break if token.nil? || token.empty?
          raise ProviderError, "SES repeated a pagination token" if tokens.include?(token)

          tokens << token
        end
        Snapshot.new(entries: entries, scope: @configuration.scope, complete: true, policy_verified: policy.verified,
                     policy_reason: policy.reason, started_at: started_at, finished_at: Time.current)
      end

      def lookup(email)
        request { client.get_suppressed_destination(email_address: email) }
        :present
      rescue Aws::SESV2::Errors::NotFoundException
        :absent
      end

      def release(entries)
        outcomes = []
        entries.each do |entry|
          result = "removed"
          begin
            request { client.delete_suppressed_destination(email_address: entry.email) }
          rescue Aws::SESV2::Errors::NotFoundException
            # Only the exact provider identifier is checked; never substitute lowercase.
            result = "already_absent"
          end
          raise ProviderError, "SES restriction remains after recovery" unless lookup(entry.email) == :absent

          outcomes << { "email" => entry.email, "result" => result }
        rescue ProviderError => e
          outcomes << { "email" => entry.email, "result" => "failed", "error_class" => e.class.name }
          remaining = entries.reject { |candidate| outcomes.any? { |outcome| outcome["email"] == candidate.email } }
          outcomes.concat(remaining.map { |candidate| { "email" => candidate.email, "result" => "not_attempted" } })
          raise ReleaseFailed.new("SES recovery did not finish; review the per-address outcomes", outcomes: outcomes)
        end
        outcomes
      end

      def authenticate(raw_body:, **)
        require_sdk("sns")
        require_relative "sns_verifier"
        @authenticator ||= SnsVerifier.new(@configuration)
        @authenticator.call(raw_body)
      end

      def control(envelope) # rubocop:disable Naming/PredicateMethod -- Adapter operation with side effects.
        case envelope.fetch("Type")
        when "SubscriptionConfirmation"
          request { sns_client.confirm_subscription(topic_arn: envelope.fetch("TopicArn"), token: envelope.fetch("Token")) }
          Store.event!("subscription_confirmed", source: "webhook")
          true
        when "UnsubscribeConfirmation"
          Store.event!("subscription_unsubscribed", source: "webhook")
          true
        else
          false
        end
      end

      def parse(envelope)
        SesParser.new(@configuration).call(envelope)
      end

      def doctor
        policy = policy_check
        { "scope" => @configuration.scope, "policy_verified" => policy.verified, "policy_reason" => policy.reason,
          "topic_allowlist" => @settings.topic_arns.any?, "topics" => topic_checks,
          "write_permissions" => "unknown; never tested by mutation" }
      end

      private

      def require_sdk(service)
        require "aws-sdk-#{service}"
      rescue LoadError
        raise ConfigurationError, "Install the optional adapter dependency: bundle add aws-sdk-#{service}"
      end

      def client
        require_sdk("sesv2")
        @client ||= @settings.client || Aws::SESV2::Client.new(region: @settings.region, retry_limit: 2,
                                                               http_open_timeout: 3, http_read_timeout: 10)
      end

      def sns_client
        require_sdk("sns")
        @sns_client ||= @settings.sns_client || Aws::SNS::Client.new(region: @settings.region, retry_limit: 2,
                                                                     http_open_timeout: 3, http_read_timeout: 10)
      end

      def sts_client
        require_sdk("sts")
        @sts_client ||= @settings.sts_client || Aws::STS::Client.new(region: @settings.region, retry_limit: 2,
                                                                     http_open_timeout: 3, http_read_timeout: 10)
      end

      def request
        yield
      rescue Seahorse::Client::NetworkingError => e
        raise ProviderError, "AWS transport failed (#{e.class.name})"
      rescue Aws::Errors::ServiceError => e
        raise if defined?(Aws::SESV2::Errors::NotFoundException) && e.is_a?(Aws::SESV2::Errors::NotFoundException)

        raise ProviderError, "AWS request failed (#{e.code})"
      end

      # Verifies that the configured scope matches the credentials and that every listed sending
      # path uses account-level suppression for both bounces and complaints. Until this passes,
      # sync runs in observation mode: entries are mirrored but nothing is enforced, and the
      # reason is reported by the sync event and by `bouncy:doctor`.
      def policy_check
        region = @settings.region
        raise ConfigurationError, "Set config.ses.region" unless region.to_s.match?(/\A[a-z]{2}(?:-[a-z]+)+-\d\z/)

        # Resolve clients before request's typed AWS rescue clauses are needed.
        sts = sts_client
        account = request { sts.get_caller_identity }.account
        expected = "ses:#{account}:#{region}:account"
        raise UnsafeSnapshot, "Configured scope does not match AWS credentials and region" unless @configuration.scope == expected

        ses = client
        raise UnsafeSnapshot, "SES client region differs from configured scope" unless ses.config.region == region

        reasons = request { ses.get_account }.suppression_attributes&.suppressed_reasons || []
        unless reasons.sort == %w[BOUNCE COMPLAINT]
          return PolicyCheck.new(verified: false, reason: "the SES account-level suppression list covers #{reasons.inspect}; " \
                                                          "Bouncy needs both BOUNCE and COMPLAINT enabled for the account")
        end
        unless @settings.all_sending_paths_listed
          return PolicyCheck.new(verified: false, reason: "config.ses.all_sending_paths_listed is false: list every identity and " \
                                                          "configuration set you send through, then set it to true")
        end

        sets = @settings.configuration_sets.dup
        @settings.identities.each do |identity|
          response = request { ses.get_email_identity(email_identity: identity) }
          sets << response.configuration_set_name if response.configuration_set_name.present?
        end
        sets.uniq.each do |name|
          suppression = request { ses.get_configuration_set(configuration_set_name: name) }.suppression_options
          next if suppression.nil? || suppression.suppressed_reasons.nil? || suppression.suppressed_reasons.sort == %w[BOUNCE COMPLAINT]

          return PolicyCheck.new(verified: false, reason: "configuration set #{name} overrides suppression with " \
                                                          "#{suppression.suppressed_reasons.inspect}; Bouncy needs BOUNCE and COMPLAINT")
        end
        PolicyCheck.new(verified: true, reason: nil)
      end

      def topic_checks
        sns = sns_client
        @settings.topic_arns.to_h do |arn|
          response = request { sns.get_topic_attributes(topic_arn: arn) }
          # Expose an explicit manual check; do not pretend a generic IAM evaluator.
          policy = JSON.parse(response.attributes.fetch("Policy", "{}"))
          [arn, { "readable" => true, "publisher_policy_review_required" => true,
                  "statements" => Array(policy["Statement"]).size }]
        end
      end

      def reason(value)
        case value
        when "BOUNCE" then :hard_bounce
        when "COMPLAINT" then :complaint
        else raise ProviderError, "Unknown SES suppression reason"
        end
      end
    end
  end
end
