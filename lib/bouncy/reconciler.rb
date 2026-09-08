# frozen_string_literal: true

module Bouncy
  class Reconciler
    def initialize(adapter)
      @adapter = adapter
    end

    def call
      ScopeLock.synchronize { reconcile }
    end

    private

    def reconcile
      started_at = Time.current
      versions = Suppression.where(scope: Bouncy.scope).pluck(:email, :lock_version).to_h
      snapshot = @adapter.snapshot
      raise UnsafeSnapshot, "Provider returned a different scope" unless snapshot.scope == Bouncy.scope

      grouped = snapshot.entries.group_by { |entry| Identity.normalize(entry.email) }
      grouped.each do |email, entries|
        previous = Suppression.find_by(scope: Bouncy.scope, email: email)
        retained = []
        if snapshot.complete && previous
          listed = entries.map(&:email)
          retained = previous.provider_entries.reject { |entry| listed.include?(entry["email"]) }.reject do |entry|
            @adapter.lookup(entry.fetch("email")) == :absent
          end
        end
        Store.change(email) do |row|
          next unless unchanged?(row, versions, started_at)

          current = entries.reject { |entry| row.released_before && entry.updated_at <= row.released_before }
          next if current.empty?

          was_blocked = row.blocked?
          row.provider_entries = (snapshot.complete ? retained + current.map(&:to_h) : (row.provider_entries + current.map(&:to_h))).uniq do |entry|
            entry["email"]
          end
          row.provider_checked_at = snapshot.finished_at
          if snapshot.policy_verified
            row.provider_blocked_at ||= current.map(&:updated_at).min
            row.provider_reason = row.provider_entries.any? { |entry| entry["reason"] == "complaint" } ? "complaint" : "hard_bounce"
          end
          row.details = row.details.except("absence_count")
          row.summarize!
          Store.event!("sync_added", email: email, source: "sync", details: { "became_blocked" => !was_blocked && row.blocked? })
        end
      end
      if snapshot.complete && snapshot.policy_verified
        Suppression.where(scope: Bouncy.scope).find_each do |row|
          next if grouped.key?(row.email) || !unchanged?(row, versions, started_at)

          check_absence(row, snapshot)
        end
      end
      Store.event!("sync", source: "sync", details: { "complete" => snapshot.complete && snapshot.policy_verified,
                                                      "enumerated" => snapshot.complete, "policy_verified" => snapshot.policy_verified,
                                                      "entries" => snapshot.entries.size,
                                                      "started_at" => started_at.iso8601(6), "finished_at" => Time.current.iso8601(6) })
    rescue ProviderError => e
      Store.event!("sync", source: "sync", details: { "complete" => false, "error_class" => e.class.name })
      raise
    end

    def unchanged?(row, versions, started_at)
      versions.key?(row.email) ? row.lock_version == versions[row.email] : row.created_at >= started_at && row.lock_version.zero? && row.released_before.nil?
    end

    def check_absence(row, snapshot)
      version = row.lock_version
      identifiers = row.provider_entries.map { |entry| entry.fetch("email") }
      identifiers << row.details.fetch("exact_email", row.email) if identifiers.empty?
      return unless identifiers.all? { |email| @adapter.lookup(email) == :absent }

      Store.change(row.email) do |current|
        next unless current.lock_version == version

        current.provider_entries = []
        current.provider_blocked_at = current.provider_reason = nil
        current.provider_checked_at = snapshot.finished_at
        if current.event_blocked_at && current.event_blocked_at < 1.hour.ago
          count = current.details.fetch("absence_count", 0) + 1
          current.details = current.details.merge("absence_count" => count)
          if count >= 2
            current.released_before = [current.released_before, current.event_blocked_at].compact.max
            current.event_blocked_at = current.event_reason = nil
          end
        end
        current.summarize!
        Store.event!("sync_released", email: current.email, source: "sync")
      end
    end
  end
end
