# frozen_string_literal: true

module Bouncy
  class Configuration
    class Ses
      # sns_message_verifier replaces ONLY the Aws::SNS::MessageVerifier that downloads and
      # caches Amazon's signing certificate, so a host can test its mounted receiver offline.
      # Topic authorization and certificate-URL checks still run, which is the point: a test
      # seam that skipped them would hide exactly the hole they exist to close.
      attr_accessor :region, :topic_arns, :client, :sns_client, :sts_client, :sns_message_verifier,
                    :identities, :configuration_sets, :all_sending_paths_listed

      def initialize
        @topic_arns = []
        @identities = []
        @configuration_sets = []
        # Imported provider restrictions are enforced only after the policy check passes, and the
        # check needs every sending identity and configuration set listed. This flag is the
        # installer's statement that the lists above are complete.
        @all_sending_paths_listed = false
      end
    end

    # A soft bounce is a temporary refusal, so one of them says nothing. Repeated soft bounces
    # for the same address inside a window are a different signal, and some hosts want them to
    # stop the sending. Leave the threshold nil to keep soft bounces record-only.
    SOFT_BOUNCE_OCCURRENCE_LIMIT = 50

    attr_accessor :provider, :scope, :interception, :record_deliveries,
                  :retention, :maximum_event_age, :stale_after, :after_block, :after_release,
                  :after_event, :adapter, :soft_bounce_threshold, :soft_bounce_window,
                  :soft_bounce_block_for
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
      @ses = Ses.new
      @after_block = @after_release = @after_event = ->(_event) {}
    end

    # Occurrence times retained per address so the window can roll. Bounded either way: a
    # configured threshold needs no more entries than the threshold itself.
    def soft_bounce_occurrences
      return SOFT_BOUNCE_OCCURRENCE_LIMIT unless soft_bounce_escalation?

      [soft_bounce_threshold, SOFT_BOUNCE_OCCURRENCE_LIMIT].min
    end

    def soft_bounce_escalation? = soft_bounce_threshold.to_i.positive?

    def configured? = !scope.to_s.strip.empty?

    def validate!
      raise ConfigurationError, "Set config.scope to the provider account and region" unless configured?
      raise ConfigurationError, "scope must be at most 191 characters" if scope.to_s.length > 191
      raise ConfigurationError, "Only the SES provider is supported" unless provider == :ses || adapter
      raise ConfigurationError, "interception must be :log, :drop or :off" unless %i[log drop off].include?(interception)
      unless maximum_event_age.positive? && retention >= maximum_event_age
        raise ConfigurationError, "retention must cover maximum_event_age, and both must be positive"
      end
      if soft_bounce_threshold && !(soft_bounce_threshold.is_a?(Integer) && soft_bounce_threshold.positive?)
        raise ConfigurationError, "soft_bounce_threshold must be a positive integer, or nil to keep soft bounces record-only"
      end
      if soft_bounce_escalation? && !(soft_bounce_window.to_i.positive? && soft_bounce_block_for.to_i.positive?)
        raise ConfigurationError, "soft_bounce_window and soft_bounce_block_for must be positive durations"
      end

      self
    end
  end
end
