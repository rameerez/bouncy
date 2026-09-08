# frozen_string_literal: true

module Bouncy
  class Recovery
    def initialize(adapter)
      @adapter = adapter
    end

    def call(email, note:, actor:, at:)
      raise ArgumentError, "at must be :local or :provider" unless %i[local provider].include?(at)
      raise ArgumentError, "A recovery note is required" if at == :provider && note.to_s.strip.empty?

      key = Identity.normalize(email)
      row = Store.change(key) { |record| record }
      version = row.lock_version
      started_at = Time.current
      if at == :provider
        snapshot = @adapter.snapshot
        unless snapshot.complete && snapshot.policy_verified && snapshot.scope == Bouncy.scope
          raise UnsafeSnapshot, "Release requires a complete snapshot of the configured sending scope"
        end

        entries = snapshot.entries.select { |entry| Identity.normalize(entry.email) == key }
        # Historical exact identifiers still need checking if a list page raced a write.
        entries += row.provider_entries.map do |entry|
          Providers::Entry.new(email: entry.fetch("email"), reason: entry.fetch("reason"), updated_at: Time.iso8601(entry.fetch("provider_updated_at")))
        end
        outcomes = @adapter.release(entries.uniq(&:email))
      end
      Store.change(key) do |current|
        raise ReleaseConflict, "Address changed during recovery; review its latest state and retry" if current.lock_version != version

        current.manual_blocked_at = current.manual_note = current.soft_blocked_until = nil
        # Recovery clears the soft-bounce history too. Without this, one soft bounce after a
        # release would meet the threshold again immediately and re-hold the address.
        current.soft_bounce_count = 0
        current.last_soft_bounce_at = nil
        current.details = current.details.except("soft_bounces")
        if at == :provider
          current.provider_entries = []
          current.provider_blocked_at = current.provider_reason = current.event_blocked_at = current.event_reason = nil
          current.provider_checked_at = Time.current
          current.released_before = started_at
        end
        current.summarize!
        Store.event!("release", email: key, details: { "at" => at.to_s, "note" => note.to_s.truncate(1000),
                                                       "actor" => actor.to_s.truncate(200), "outcomes" => outcomes })
        current
      end
    rescue ProviderError, ReleaseConflict => e
      Store.event!("release_failed", email: key, details: { "error_class" => e.class.name,
                                                            "outcomes" => e.is_a?(ReleaseFailed) ? e.outcomes : [] })
      raise
    end
  end
end
