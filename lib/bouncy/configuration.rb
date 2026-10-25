# frozen_string_literal: true

module Bouncy
  class Configuration
    class Ses
      # sns_message_verifier replaces ONLY the Aws::SNS::MessageVerifier that downloads and
      # caches Amazon's signing certificate, so a host can test its mounted receiver offline.
      # Topic authorization and certificate-URL checks still run, which is the point: a test
      # seam that skipped them would hide exactly the hole they exist to close.
      #
      # configuration_set names the SES configuration set that the interceptor stamps on every
      # message (X-SES-CONFIGURATION-SET), so SES publishes that mail's events to the set's topic.
      # The set also joins the sending-policy check. A blank name stamps nothing.
      #
      # subscription_confirmation picks how the receiver confirms an SNS subscription: :api calls
      # sns:ConfirmSubscription with the signed token; :subscribe_url visits the signed
      # SubscribeURL instead, for credentials without that grant.
      attr_accessor :region, :credentials, :topic_arns, :client, :sns_client, :sts_client, :sns_message_verifier,
                    :identities, :configuration_sets, :all_sending_paths_listed, :configuration_set,
                    :subscription_confirmation

      def initialize
        @topic_arns = []
        @identities = []
        @configuration_sets = []
        # Imported provider restrictions are enforced only after the policy check passes, and the
        # check needs every sending identity and configuration set listed. This flag is the
        # installer's statement that the lists above are complete.
        @all_sending_paths_listed = false
        @subscription_confirmation = :api
      end
    end

    # A soft bounce is a temporary refusal, so one of them says nothing. Repeated soft bounces
    # for the same address inside a window are a different signal, and some hosts want them to
    # stop the sending. Leave the threshold nil to keep soft bounces record-only.
    SOFT_BOUNCE_OCCURRENCE_LIMIT = 50

    # require_fresh_sync: true enforces provider and webhook evidence only while a complete sync
    # is fresh. false enforces it always, for an app that runs no sync job: on an SES account
    # that other apps share, their suppressions stay out of this app's tables.
    #
    # on_notification is called with every SES notification, after its state commits and before
    # the receiver answers. Unlike the after_* hooks it may raise: the receiver then answers 503,
    # and SNS delivers the notification again.
    #
    # webhook_blocking picks which notifications block an address. :cautious blocks General and
    # NoEmail bounces and complaints that name one recipient, and leaves the rest to the sync,
    # which reads the account list. :strict blocks every Permanent bounce, whatever its subtype,
    # and every recipient a complaint names. It defaults to :cautious while a sync runs and to
    # :strict when require_fresh_sync is false, because then nothing reads the account list.
    attr_writer :webhook_blocking
    attr_accessor :provider, :scope, :interception, :record_deliveries,
                  :retention, :maximum_event_age, :stale_after, :after_block, :after_release,
                  :after_event, :adapter, :soft_bounce_threshold, :soft_bounce_window,
                  :soft_bounce_block_for, :require_fresh_sync, :on_notification
    attr_reader :ses

    def initialize
      @provider = :ses
      @interception = :log
      @record_deliveries = false
      @retention = 90.days
      @maximum_event_age = 90.days
      @stale_after = 2.hours
      @soft_bounce_threshold = nil
      @soft_bounce_window = 30.days
      @soft_bounce_block_for = 30.days
      @require_fresh_sync = true
      @ses = Ses.new
      @after_block = @after_release = @after_event = ->(_event) {}
      @on_notification = ->(_notification) {}
    end

    # Occurrence times retained per address so the window can roll. Bounded either way: a
    # configured threshold needs no more entries than the threshold itself.
    def soft_bounce_occurrences
      return SOFT_BOUNCE_OCCURRENCE_LIMIT unless soft_bounce_escalation?

      [soft_bounce_threshold, SOFT_BOUNCE_OCCURRENCE_LIMIT].min
    end

    def soft_bounce_escalation? = soft_bounce_threshold.to_i.positive?

    def webhook_blocking = @webhook_blocking || (require_fresh_sync == false ? :strict : :cautious)

    def configured? = !scope.to_s.strip.empty?

    def validate!
      raise ConfigurationError, "Set config.scope to the provider account and region" unless configured?
      raise ConfigurationError, "scope must be at most 191 characters" if scope.to_s.length > 191
      raise ConfigurationError, "Only the SES provider is supported" unless provider == :ses || adapter
      raise ConfigurationError, "interception must be :log, :drop or :off" unless %i[log drop off].include?(interception)
      raise ConfigurationError, "require_fresh_sync must be true or false" unless [true, false].include?(require_fresh_sync)
      raise ConfigurationError, "webhook_blocking must be :cautious or :strict" unless %i[cautious strict].include?(webhook_blocking)
      unless %i[api subscribe_url].include?(ses.subscription_confirmation)
        raise ConfigurationError, "ses.subscription_confirmation must be :api or :subscribe_url"
      end
      unless ses.configuration_set.nil? || ses.configuration_set.is_a?(String)
        raise ConfigurationError, "ses.configuration_set must be the name of an SES configuration set, or nil"
      end
      unless maximum_event_age.positive? && retention >= maximum_event_age
        raise ConfigurationError, "retention must cover maximum_event_age, and both must be positive"
      end
      if soft_bounce_threshold && !(soft_bounce_threshold.is_a?(Integer) && (1..SOFT_BOUNCE_OCCURRENCE_LIMIT).cover?(soft_bounce_threshold))
        raise ConfigurationError, "soft_bounce_threshold must be an integer from 1 to #{SOFT_BOUNCE_OCCURRENCE_LIMIT}, or nil"
      end
      unless [soft_bounce_window, soft_bounce_block_for].all? { |duration| duration.is_a?(Numeric) || duration.is_a?(ActiveSupport::Duration) } &&
             soft_bounce_window.positive? && soft_bounce_block_for.positive?
        raise ConfigurationError, "soft_bounce_window and soft_bounce_block_for must be positive durations"
      end

      self
    end
  end
end
