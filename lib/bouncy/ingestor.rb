# frozen_string_literal: true

module Bouncy
  Observation = Data.define(:email, :kind, :provider_event_id, :message_id, :occurred_at, :details, :provider_reason, :status_code, :diagnostic)

  class Ingestor
    def call(observation)
      email = observation.email && Identity.normalize(observation.email)
      attributes = observation.to_h.merge(email: email)
      identity = [Bouncy.scope, Bouncy.configuration.provider, observation.provider_event_id, observation.kind, email]
      attributes[:dedupe_key] = Digest::SHA256.hexdigest(JSON.generate(identity))
      return :duplicate if duplicate?(attributes[:dedupe_key])

      if email
        Store.change(email) do |row|
          # Re-check under the row lock so a concurrent retry becomes a duplicate, not a unique violation.
          next :duplicate if duplicate?(attributes[:dedupe_key])

          persist(attributes, row)
        end
      else
        Event.transaction { persist(attributes, nil) }
      end
    rescue ActiveRecord::RecordNotUnique
      # The unique event and its state transition committed in the same transaction.
      raise unless duplicate?(attributes[:dedupe_key])

      :duplicate
    end

    private

    def duplicate?(key)
      Bouncy.events.exists?(dedupe_key: key)
    end

    def persist(attributes, row)
      time = attributes.fetch(:occurred_at)
      too_old = time < Bouncy.configuration.maximum_event_age.ago || time > 5.minutes.from_now
      fenced = row&.released_before && time <= row.released_before
      out_of_order = row&.last_event_at && time < row.last_event_at
      details = attributes.fetch(:details).merge("ignored_for_policy" => [too_old, fenced, out_of_order].any?)
      if row && !details["ignored_for_policy"]
        was_blocked = row.blocked?
        # A complaint blocks locally only when the provider named exactly one recipient (SesParser
        # marks it "confirmed"); candidates wait for the provider's own list at the next sync.
        if attributes[:kind] == "hard_bounce" || (attributes[:kind] == "complaint" && details["certainty"] == "confirmed")
          row.event_blocked_at = time
          row.event_reason = attributes[:kind]
          row.last_event_at = time
          row.details = row.details.except("absence_count")
          row.details["exact_email"] = details["exact_email"] if details["exact_email"]
        elsif attributes[:kind] == "soft_bounce"
          count_soft_bounce(row, time, details)
        end
        row.summarize!
        details["became_blocked"] = !was_blocked && row.blocked?
      end
      Store.event!(attributes.fetch(:kind), **attributes.except(:kind, :details), source: "webhook",
                                                                                  provider: Bouncy.configuration.provider.to_s, details: details)
      :accepted
    end

    # Records this soft bounce against the address and, once config.soft_bounce_threshold of them
    # fall inside config.soft_bounce_window, holds the address for config.soft_bounce_block_for.
    # The occurrence times are kept so the window really rolls: a bounce that ages out stops
    # counting, instead of a running total that only ever grows. Redelivered notifications are
    # already filtered by the event dedupe key before this runs. With no threshold configured a
    # soft bounce only updates the counters, which is the default.
    def count_soft_bounce(row, time, details)
      window = Bouncy.configuration.soft_bounce_window
      previous = Array(row.details["soft_bounces"]).filter_map { |value| parse_time(value) }
      occurrences = (previous.select { |occurred_at| occurred_at > time - window } + [time]).sort
      occurrences = occurrences.last(Bouncy.configuration.soft_bounce_occurrences)
      row.details = row.details.merge("soft_bounces" => occurrences.map { |occurred_at| occurred_at.iso8601(6) })
      row.soft_bounce_count = occurrences.size
      row.last_soft_bounce_at = time
      row.last_event_at = time
      details["soft_bounce_count"] = occurrences.size
      return unless Bouncy.configuration.soft_bounce_escalation? && occurrences.size >= Bouncy.configuration.soft_bounce_threshold

      row.soft_blocked_until = time + Bouncy.configuration.soft_bounce_block_for
      details["soft_blocked_until"] = row.soft_blocked_until.iso8601(6)
    end

    def parse_time(value)
      Time.iso8601(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end
  end
end
