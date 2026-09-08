# frozen_string_literal: true

module Bouncy
  Observation = Data.define(:email, :kind, :provider_event_id, :message_id, :occurred_at, :details, :provider_reason, :status_code, :diagnostic)

  class Ingestor
    def call(observation)
      email = observation.email && Identity.normalize(observation.email)
      attributes = observation.to_h.merge(email: email)
      identity = [Bouncy.scope, Bouncy.configuration.provider, observation.provider_event_id, observation.kind, email]
      attributes[:dedupe_key] = Digest::SHA256.hexdigest(JSON.generate(identity))
      return :duplicate if Bouncy.events.exists?(dedupe_key: attributes[:dedupe_key])

      if email
        Store.change(email) { |row| persist(attributes, row) }
      else
        Event.transaction { persist(attributes, nil) }
      end
    rescue ActiveRecord::RecordNotUnique
      # The unique event and its state transition committed in the same transaction.
      raise unless Bouncy.events.exists?(dedupe_key: attributes[:dedupe_key])

      :duplicate
    end

    private

    def persist(attributes, row)
      time = attributes.fetch(:occurred_at)
      too_old = time < Bouncy.configuration.maximum_event_age.ago || time > 5.minutes.from_now
      fenced = row&.released_before && time <= row.released_before
      out_of_order = row&.last_event_at && time < row.last_event_at
      details = attributes.fetch(:details).merge("ignored_for_policy" => [too_old, fenced, out_of_order].any?)
      if row && !details["ignored_for_policy"]
        was_blocked = row.blocked?
        if attributes[:kind] == "hard_bounce" || (attributes[:kind] == "complaint" && details["certainty"] == "confirmed")
          row.event_blocked_at = time
          row.event_reason = attributes[:kind]
          row.last_event_at = time
          row.details = row.details.except("absence_count")
          row.details["exact_email"] = details["exact_email"] if details["exact_email"]
        end
        row.summarize!
        details["became_blocked"] = !was_blocked && row.blocked?
      end
      Store.event!(attributes.fetch(:kind), **attributes.except(:kind, :details), source: "webhook",
                                                                                  provider: Bouncy.configuration.provider.to_s, details: details)
      :accepted
    end
  end
end
