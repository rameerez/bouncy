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

    # Pages are applied as the adapter reads them, so memory holds one page plus two compact
    # per-address tables: the lock versions at the start (local rows) and the addresses listed
    # so far. Both are keyed by String#hash. A collision can only skip a change or an absence
    # check for one run, never clear a restriction.
    def reconcile
      started_at = Time.current
      deadline = Providers::Deadline.new(Bouncy.configuration.sync_max_duration)
      versions = {}
      Suppression.where(scope: Bouncy.scope).in_batches(of: 10_000) do |batch|
        deadline.check!
        batch.pluck(:email, :lock_version).each do |email, version|
          deadline.check!
          versions[email.hash] = version
        end
      end
      listed = Set.new
      counts = Hash.new(0)
      total = 0
      deadline.check!
      limits = Bouncy.configuration.sync_limits.with(deadline: deadline)
      snapshot = @adapter.scan(limits) do |page|
        raise UnsafeSnapshot, "Provider returned a different scope" unless page.scope == Bouncy.scope

        deadline.check!
        total += page.entries.size
        page.entries.group_by { |entry| Identity.normalize(entry.email) }.each do |email, entries|
          deadline.check!
          listed << email.hash
          counts[apply_listed(email, entries, page, versions, started_at)] += 1
        end
      end
      deadline.check! if snapshot.complete
      raise UnsafeSnapshot, "Provider returned a different scope" unless snapshot.scope == Bouncy.scope

      # Only a list read to its end, under a verified policy, can show that an address is gone.
      if snapshot.complete && snapshot.policy_verified
        # All absence changes roll back if the deadline expires during the pass. This keeps a
        # timed-out sync add-only even if it had already checked some absent addresses.
        absence_counts = Hash.new(0)
        Suppression.transaction(requires_new: true) do
          Suppression.where(scope: Bouncy.scope).find_each do |row|
            deadline.check!
            next if listed.include?(row.email.hash) || !unchanged?(row, versions, started_at)

            absence_counts[check_absence(row, snapshot)] += 1
            deadline.check!
          end
          deadline.check!
        end
        absence_counts.each { |kind, count| counts[kind] += count }
      end
      if snapshot.incomplete_reason
        Rails.logger&.warn("[bouncy] sync stopped before the end of the provider list: #{snapshot.incomplete_reason}; " \
                           "no restriction was cleared")
      end
      details = { "complete" => snapshot.complete && snapshot.policy_verified, "enumerated" => snapshot.complete,
                  "policy_verified" => snapshot.policy_verified, "policy_reason" => snapshot.policy_reason,
                  "entries" => total, "added" => counts[:added], "updated" => counts[:updated],
                  "released" => counts[:released], "unchanged" => counts[:unchanged],
                  "started_at" => started_at.iso8601(6), "finished_at" => Time.current.iso8601(6) }
      details["incomplete_reason"] = snapshot.incomplete_reason if snapshot.incomplete_reason
      Store.event!("sync", source: "sync", details: details)
    rescue Providers::DeadlineExceeded => e
      Rails.logger&.warn("[bouncy] sync exceeded its deadline: #{e.message}; no absence restriction was cleared")
      Store.event!("sync", source: "sync", details: { "complete" => false, "enumerated" => !!snapshot&.complete,
                                                      "policy_verified" => snapshot&.policy_verified, "incomplete_reason" => e.message,
                                                      "entries" => total || 0, "added" => counts&.[](:added).to_i, "released" => 0,
                                                      "started_at" => started_at.iso8601(6), "finished_at" => Time.current.iso8601(6) })
    rescue ProviderError => e
      details = { "complete" => false, "error_class" => e.class.name }
      if e.policy_check&.verified == false
        details["policy_verified"] = false
        details["policy_reason"] = e.policy_check.reason
      end
      Store.event!("sync", source: "sync", details: details)
      raise
    end

    # Applies the listed entries of one page for one normalized address. An address whose
    # spellings fall on two pages is applied twice; the version of this run's own write is
    # recorded, so the second page is not mistaken for a concurrent change.
    # Returns :added, :updated, :unchanged or :skipped.
    def apply_listed(email, entries, page, versions, started_at)
      previous = Suppression.find_by(scope: Bouncy.scope, email: email)
      retained = []
      if page.authoritative && previous
        listed = entries.map(&:email)
        retained = previous.provider_entries.reject { |entry| listed.include?(entry["email"]) }.reject do |entry|
          @adapter.lookup(entry.fetch("email")) == :absent
        end
      end
      Store.change(email) do |row|
        next :skipped unless unchanged?(row, versions, started_at)

        current = entries.reject { |entry| row.released_before && entry.updated_at <= row.released_before }
        next :skipped if current.empty?

        merged = (page.authoritative ? retained + current.map(&:to_h) : row.provider_entries + current.map(&:to_h))
        merged = merged.group_by { |entry| entry["email"] }.values.map do |variants|
          variants.max_by { |entry| Time.iso8601(entry.fetch("provider_updated_at")) }
        end
        was_blocked = row.blocked?
        before = restriction_of(row)
        row.provider_entries = merged
        row.provider_checked_at = page.observed_at
        if page.policy_verified
          row.provider_blocked_at ||= current.map(&:updated_at).min
          row.provider_reason = merged.any? { |entry| entry["reason"] == "complaint" } ? "complaint" : "hard_bounce"
        end
        row.details = row.details.except("absence_count")
        if before == restriction_of(row)
          # New evidence must fence a concurrent recovery even when the restriction is unchanged.
          if row.provider_entries_was.sort_by { |entry| entry["email"] } == merged.sort_by { |entry| entry["email"] }
            row.update_columns(provider_checked_at: page.observed_at)
          else
            row.save!
          end
          versions[email.hash] = row.lock_version
          next :unchanged
        end

        row.summarize!
        versions[email.hash] = row.lock_version
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
      key = row.email.hash
      versions.key?(key) ? row.lock_version == versions[key] : row.created_at >= started_at && row.lock_version.zero? && row.released_before.nil?
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
