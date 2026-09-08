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

    # Current scoped verification is separate from retained restriction evidence.
    def policy_unverified? = provider_listed? && policy_details["policy_verified"] != true
    def policy_reason = policy_unverified? ? (policy_details["policy_reason"] || "Sending policy could not be verified") : nil

    def stale?
      %i[unavailable unconfigured].include?(knowledge) || observed_at.nil? || observed_at < Bouncy.configuration.stale_after.ago
    end

    private

    def policy_details
      @policy_details ||= Event.where(scope: scope, kind: "sync").order(created_at: :desc, id: :desc).pick(:details) ||
                          { "policy_reason" => "Sending policy has not been checked" }
    rescue ActiveRecord::ActiveRecordError => e
      raise unless Bouncy.database_unavailable?(e)

      @policy_details = { "policy_reason" => "Sending policy is unavailable because the database could not be reached" }
    end
  end
end
