# frozen_string_literal: true

module Bouncy
  class Status
    attr_reader :scope, :provider, :knowledge

    # knowledge: :observed, :no_known_block, :unavailable (recognized database outage)
    # or :unconfigured (config.scope is not set; Bouncy is inactive).
    def initialize(row, knowledge: nil, unavailable: false)
      @row = row
      @scope = Bouncy.configuration.scope
      @provider = Bouncy.configuration.provider
      @knowledge = knowledge
      @knowledge ||= if unavailable
                       :unavailable
                     elsif row
                       :observed
                     else
                       :no_known_block
                     end
    end

    def blocked? = @row ? @row.blocked? : false
    def reasons = @row ? @row.reasons : []
    def reason = (%i[complaint hard_bounce provider_list manual soft_bounces] & reasons).first
    def observed_at = @row&.provider_checked_at || @row&.last_event_at
    def provider_updated_at = @row&.provider_entries&.filter_map { |entry| Time.iso8601(entry.fetch("provider_updated_at")) }&.max
    def last_event = @row && Bouncy.events.for(@row.email).recent.first
    def release_supported? = %i[unavailable unconfigured].exclude?(knowledge) && provider.to_sym == :ses

    # The provider lists this address in the configured scope.
    def provider_listed? = @row ? @row.provider_entries.any? : false

    # Listed by the provider but not enforced locally because the sending policy has not been
    # verified (see config.ses.all_sending_paths_listed and `bouncy:doctor`).
    def policy_unverified? = provider_listed? && @row.provider_blocked_at.nil?

    def stale?
      %i[unavailable unconfigured].include?(knowledge) || observed_at.nil? || observed_at < Bouncy.configuration.stale_after.ago
    end
  end
end
