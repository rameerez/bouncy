# frozen_string_literal: true

module Bouncy
  # Reconciles the provider's suppression list with local state under the scope lock.
  #
  # Idempotency contract: a snapshot that changes nothing about an address writes no
  # event, fires no hook and does not bump the row's lock version. Only the observation
  # time (provider_checked_at) is refreshed. Changed provider metadata advances the
  # version to fence concurrent recovery, without a restriction event. Rows with neither
  # provider evidence nor a webhook-derived block are never looked up at the provider.
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

      counts = Hash.new(0)
      grouped = snapshot.entries.group_by { |entry| Identity.normalize(entry.email) }
      grouped.each { |email, entries| counts[apply_listed(email, entries, snapshot, versions, started_at)] += 1 }
      if snapshot.complete && snapshot.policy_verified
        Suppression.where(scope: Bouncy.scope).find_each do |row|
          next if grouped.key?(row.email) || !unchanged?(row, versions, started_at)

          counts[check_absence(row, snapshot)] += 1
        end
      end
      Store.event!("sync", source: "sync", details: {
                     "complete" => snapshot.complete && snapshot.policy_verified, "enumerated" => snapshot.complete,
                     "policy_verified" => snapshot.policy_verified, "policy_reason" => snapshot.policy_reason,
                     "entries" => snapshot.entries.size, "added" => counts[:added], "updated" => counts[:updated],
                     "released" => counts[:released], "unchanged" => counts[:unchanged],
                     "started_at" => started_at.iso8601(6), "finished_at" => Time.current.iso8601(6)
                   })
    rescue ProviderError => e
      Store.event!("sync", source: "sync", details: { "complete" => false, "error_class" => e.class.name })
      raise
    end

    # Applies the listed entries for one normalized address.
    # Returns :added, :updated, :unchanged or :skipped.
    def apply_listed(email, entries, snapshot, versions, started_at)
      previous = Suppression.find_by(scope: Bouncy.scope, email: email)
      retained = []
      if snapshot.complete && previous
        listed = entries.map(&:email)
        retained = previous.provider_entries.reject { |entry| listed.include?(entry["email"]) }.reject do |entry|
          @adapter.lookup(entry.fetch("email")) == :absent
        end
      end
      Store.change(email) do |row|
        next :skipped unless unchanged?(row, versions, started_at)

        current = entries.reject { |entry| row.released_before && entry.updated_at <= row.released_before }
        next :skipped if current.empty?

        merged = (snapshot.complete ? retained + current.map(&:to_h) : row.provider_entries + current.map(&:to_h))
        merged = merged.group_by { |entry| entry["email"] }.values.map do |variants|
          variants.max_by { |entry| Time.iso8601(entry.fetch("provider_updated_at")) }
        end
        was_blocked = row.blocked?
        before = restriction_of(row)
        row.provider_entries = merged
        row.provider_checked_at = snapshot.finished_at
        if snapshot.policy_verified
          row.provider_blocked_at ||= current.map(&:updated_at).min
          row.provider_reason = merged.any? { |entry| entry["reason"] == "complaint" } ? "complaint" : "hard_bounce"
        end
        row.details = row.details.except("absence_count")
        if before == restriction_of(row)
          # New evidence must fence a concurrent recovery even when the restriction is unchanged.
          if row.provider_entries_was.sort_by { |entry| entry["email"] } == merged.sort_by { |entry| entry["email"] }
            row.update_columns(provider_checked_at: snapshot.finished_at)
          else
            row.save!
          end
          next :unchanged
        end

        row.summarize!
        became_blocked = !was_blocked && row.blocked?
        kind = before.first.empty? || became_blocked ? "sync_added" : "sync_updated"
        Store.event!(kind, email: email, source: "sync", details: { "became_blocked" => became_blocked })
        kind == "sync_added" ? :added : :updated
      end
    end

    def restriction_of(row)
      [row.provider_entries.map { |entry| [entry["email"], entry["reason"]] }.sort,
       row.provider_blocked_at.present?, row.provider_reason, row.details.key?("absence_count")]
    end

    def unchanged?(row, versions, started_at)
      versions.key?(row.email) ? row.lock_version == versions[row.email] : row.created_at >= started_at && row.lock_version.zero? && row.released_before.nil?
    end

    # Handles a local row the complete, policy-verified snapshot did not list.
    # Returns :released, :unchanged or :skipped.
    def check_absence(row, snapshot)
      return :skipped if row.provider_entries.empty? && row.event_blocked_at.nil?

      version = row.lock_version
      identifiers = row.provider_entries.map { |entry| entry.fetch("email") }
      identifiers << row.details.fetch("exact_email", row.email) if identifiers.empty?
      return :skipped unless identifiers.all? { |email| @adapter.lookup(email) == :absent }

      Store.change(row.email) do |current|
        next :skipped unless current.lock_version == version

        was_blocked = current.blocked?
        released = current.provider_entries.any?
        counted = false
        current.provider_entries = []
        current.provider_blocked_at = current.provider_reason = nil
        current.provider_checked_at = snapshot.finished_at
        if current.event_blocked_at && current.event_blocked_at < 1.hour.ago
          count = current.details.fetch("absence_count", 0) + 1
          current.details = current.details.merge("absence_count" => count)
          counted = true
          if count >= 2
            current.released_before = [current.released_before, current.event_blocked_at].compact.max
            current.event_blocked_at = current.event_reason = nil
            released = true
          end
        end
        unless released || counted
          current.update_columns(provider_checked_at: snapshot.finished_at)
          next :unchanged
        end

        current.summarize!
        next :unchanged unless released

        Store.event!("sync_released", email: current.email, source: "sync",
                                      details: { "became_unblocked" => was_blocked && !current.blocked? })
        :released
      end
    end
  end
end
