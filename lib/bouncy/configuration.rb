# frozen_string_literal: true

module Bouncy
  class Configuration
    class Ses
      attr_accessor :region, :topic_arns, :client, :sns_client, :sts_client,
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

    attr_accessor :provider, :scope, :interception, :record_deliveries,
                  :retention, :maximum_event_age, :stale_after, :after_block, :after_release,
                  :after_event, :adapter
    attr_reader :ses

    def initialize
      @provider = :ses
      @interception = :log
      @record_deliveries = false
      @retention = 90.days
      @maximum_event_age = 90.days
      @stale_after = 2.hours
      @ses = Ses.new
      @after_block = @after_release = @after_event = ->(_event) {}
    end

    def configured? = !scope.to_s.strip.empty?

    def validate!
      raise ConfigurationError, "Set config.scope to the provider account and region" unless configured?
      raise ConfigurationError, "scope must be at most 191 characters" if scope.to_s.length > 191
      raise ConfigurationError, "Only the SES provider is supported" unless provider == :ses || adapter
      raise ConfigurationError, "interception must be :log, :drop or :off" unless %i[log drop off].include?(interception)
      unless maximum_event_age.positive? && retention >= maximum_event_age
        raise ConfigurationError, "retention must cover maximum_event_age, and both must be positive"
      end

      self
    end
  end
end
