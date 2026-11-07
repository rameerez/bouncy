# frozen_string_literal: true

module Bouncy
  module Providers
    class Ses < Base
      # The SNS host domain of each AWS partition, for the certificate and SubscribeURL checks.
      SNS_DOMAINS = { "aws" => "amazonaws.com", "aws-us-gov" => "amazonaws.com", "aws-cn" => "amazonaws.com.cn" }.freeze
      # SNS answers a SubscribeURL visit with a short XML document.
      CONFIRMATION_LIMIT = 64 * 1024
      # Entries per ListSuppressedDestinations request, the most SES returns.
      PAGE_SIZE = 1000
      # A subscription token is valid for three days, so an older SubscriptionConfirmation is a
      # replay, not a retry. SNS retries a delivery for at most a few hours by default.
      CONTROL_MAX_AGE = 3 * 24 * 3600
      # The clock skew a control message's Timestamp may show from the future.
      CONTROL_MAX_SKEW = 5 * 60

      # The SubscribeURL as a URI when it is HTTPS on the topic's own regional SNS host, port 443,
      # with no userinfo and no fragment; nil for any other value.
      def self.subscribe_uri(envelope, region)
        uri = URI.parse(envelope["SubscribeURL"].to_s)
        domain = SNS_DOMAINS[envelope["TopicArn"].to_s.split(":")[1]]
        return unless domain && uri.is_a?(URI::HTTPS) && uri.host == "sns.#{region}.#{domain}" && uri.port == 443
        return if uri.userinfo || uri.fragment

        uri
      rescue URI::InvalidURIError
        nil
      end

      def initialize(configuration = Bouncy.configuration)
        super()
        @configuration = configuration
        @settings = configuration.ses
      end

      # The whole list in memory, for callers that want it. Bouncy itself streams with scan.
      def snapshot(limits = @configuration.sync_limits)
        entries = []
        result = scan(limits) { |page| entries.concat(page.entries) }
        result.with(entries: entries)
      end

      # Reads the account list one page at a time and yields each page before the next request,
      # so memory holds one page, never the list. Stops, incomplete, at the first limit reached.
      def scan(limits = @configuration.sync_limits)
        started_at = Time.current
        deadline = limits.deadline || Deadline.new(limits.duration)
        policy = policy_check
        deadline.check!
        tokens = Set.new
        token = nil
        pages = count = 0
        stopped = nil
        loop do
          deadline.check!
          response = request { client.list_suppressed_destinations(page_size: PAGE_SIZE, next_token: token) }
          pages += 1
          entries = response.suppressed_destination_summaries.map do |row|
            Identity.normalize(row.email_address)
            Entry.new(email: row.email_address, reason: reason(row.reason), updated_at: row.last_update_time)
          end
          count += entries.size
          yield Page.new(entries: entries, scope: @configuration.scope, authoritative: true,
                         policy_verified: policy.verified, observed_at: Time.current)
          deadline.check!
          token = response.next_token
          break if token.nil? || token.empty?
          raise ProviderError, "SES repeated a pagination token" unless tokens.add?(token)
          break if (stopped = limits.exceeded(pages: pages, entries: count))
        end
        Snapshot.new(entries: [], scope: @configuration.scope, complete: stopped.nil?, policy_verified: policy.verified,
                     policy_reason: policy.reason, incomplete_reason: stopped, started_at: started_at, finished_at: Time.current)
      rescue DeadlineExceeded => e
        Snapshot.new(entries: [], scope: @configuration.scope, complete: false, policy_verified: policy&.verified,
                     policy_reason: policy&.reason, incomplete_reason: e.message, started_at: started_at, finished_at: Time.current)
      rescue ProviderError => e
        # Preserve an explicit negative policy finding even if listing or applying a page fails.
        e.policy_check = policy if policy&.verified == false
        raise
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

      # Each signed control message acts once. SNS sends the same MessageId again when the first
      # answer was not 2xx, and a confirmed message replayed later is answered 200 without
      # visiting SNS or recording anything again. A message older than CONTROL_MAX_AGE, or dated
      # in the future, is refused, so the dedupe record only has to outlive that age.
      def control(envelope) # rubocop:disable Naming/PredicateMethod -- Adapter operation with side effects.
        type = envelope.fetch("Type")
        return false unless CONTROL_TYPES.include?(type)

        check_control_age!(envelope)
        visit = type == "SubscriptionConfirmation" && @settings.subscription_confirmation == :subscribe_url
        uri = self.class.subscribe_uri(envelope, @settings.region) if visit
        raise MalformedMessage, "SubscribeURL is not on the topic's SNS host" if visit && !uri

        key = Digest::SHA256.hexdigest(JSON.generate([@configuration.scope, "ses", "control", type, envelope.fetch("MessageId")]))
        return true if Bouncy.events.exists?(dedupe_key: key)

        if type == "SubscriptionConfirmation"
          if visit
            visit_subscribe_url(uri)
          else
            request { sns_client.confirm_subscription(topic_arn: envelope.fetch("TopicArn"), token: envelope.fetch("Token")) }
          end
          record_control("subscription_confirmed", key, "via" => @settings.subscription_confirmation.to_s)
        else
          record_control("subscription_unsubscribed", key)
        end
        true
      end

      def parse(envelope)
        SesParser.new(@configuration).call(envelope)
      end

      # The notification for config.on_notification. parse has already checked the message.
      def notification(envelope)
        Notification.new(JSON.parse(envelope.fetch("Message"), max_nesting: 20), sns_timestamp: envelope["Timestamp"])
      end

      def doctor
        policy = policy_check
        { "scope" => @configuration.scope, "policy_verified" => policy.verified, "policy_reason" => policy.reason,
          "topic_allowlist" => @settings.topic_arns.any?, "topics" => topic_checks,
          "write_permissions" => "unknown; never tested by mutation" }
      end

      private

      CONTROL_TYPES = %w[SubscriptionConfirmation UnsubscribeConfirmation].freeze
      private_constant :CONTROL_TYPES

      def check_control_age!(envelope)
        sent_at = Time.iso8601(envelope.fetch("Timestamp"))
        # The dedupe record must outlive the age limit, so a short retention shortens the limit.
        max_age = [CONTROL_MAX_AGE, @configuration.retention.to_i].min
        raise MalformedMessage, "SNS control message is older than #{max_age}s" if sent_at < Time.current - max_age
        raise MalformedMessage, "SNS control message is dated in the future" if sent_at > Time.current + CONTROL_MAX_SKEW
      rescue ArgumentError, TypeError
        raise MalformedMessage, "SNS control message has no valid Timestamp"
      end

      # Two deliveries of one message racing each other both act, which SNS tolerates; only one
      # records it.
      def record_control(kind, key, details = {})
        Store.event!(kind, source: "webhook", dedupe_key: key, details: details)
      rescue ActiveRecord::RecordNotUnique
        nil
      end

      # Confirms the subscription by visiting the SubscribeURL that SNS signed, so the credentials
      # need no sns:ConfirmSubscription grant. control has already refused any URL that is not
      # HTTPS on the topic's own regional SNS host, as malformed for good. A transport failure or an answer
      # other than 2xx is a ProviderError: the receiver answers 503, and SNS sends the
      # confirmation again.
      def visit_subscribe_url(uri)
        require "net/http"
        code = nil
        Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 3, read_timeout: 5,
                                            verify_mode: OpenSSL::SSL::VERIFY_PEER, max_retries: 0) do |http|
          http.request(Net::HTTP::Get.new(uri.request_uri)) do |response|
            code = response.code
            size = 0
            response.read_body do |chunk|
              size += chunk.bytesize
              raise ProviderError, "SNS confirmation response exceeds limit" if size > CONFIRMATION_LIMIT
            end
          end
        end
        raise ProviderError, "SNS did not confirm the subscription (HTTP #{code})" unless code.to_s.match?(/\A2\d\d\z/)
      rescue Timeout::Error, SocketError, IOError, SystemCallError, OpenSSL::SSL::SSLError
        raise ProviderError, "SNS confirmation transport unavailable"
      end

      def require_sdk(service)
        require "aws-sdk-#{service}"
      rescue LoadError
        raise ConfigurationError, "Install the optional adapter dependency: bundle add aws-sdk-#{service}"
      end

      def client
        require_sdk("sesv2")
        @client ||= @settings.client || Aws::SESV2::Client.new(**client_options)
      end

      def sns_client
        require_sdk("sns")
        @sns_client ||= @settings.sns_client || Aws::SNS::Client.new(**client_options)
      end

      def sts_client
        require_sdk("sts")
        @sts_client ||= @settings.sts_client || Aws::STS::Client.new(**client_options)
      end

      def client_options
        { region: @settings.region, credentials: @settings.credentials, retry_limit: 2,
          http_open_timeout: 3, http_read_timeout: 10 }.compact
      end

      def request
        yield
      rescue Seahorse::Client::NetworkingError => e
        raise ProviderError, "AWS transport failed (#{e.class.name})"
      rescue Aws::Errors::MissingCredentialsError
        raise ProviderError, "AWS credentials are missing; set config.ses.credentials or configure the AWS credential chain"
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
        sets << @settings.configuration_set if @settings.configuration_set.present?
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
