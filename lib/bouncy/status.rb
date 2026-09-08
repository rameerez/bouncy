# frozen_string_literal: true

module Bouncy
  class Status
    attr_reader :scope, :provider, :knowledge

    def initialize(row, unavailable: false)
      @row = row
      @scope = Bouncy.configuration.scope
      @provider = Bouncy.configuration.provider
      @knowledge = if unavailable
                     :unavailable
                   else
                     (row ? :observed : :no_known_block)
                   end
    end

    def blocked? = @row ? @row.blocked? : false
    def reasons = @row ? @row.reasons : []
    def reason = (%i[complaint hard_bounce provider_list manual soft_bounces] & reasons).first
    def observed_at = @row&.provider_checked_at || @row&.last_event_at
    def provider_updated_at = @row&.provider_entries&.filter_map { |entry| Time.iso8601(entry.fetch("provider_updated_at")) }&.max
    def last_event = @row && Bouncy.events.for(@row.email).recent.first
    def release_supported? = knowledge != :unavailable && provider.to_sym == :ses

    def stale?
      knowledge == :unavailable || observed_at.nil? || observed_at < Bouncy.configuration.stale_after.ago
    end
  end
end
