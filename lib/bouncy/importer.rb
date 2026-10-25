# frozen_string_literal: true

module Bouncy
  # Records a block that another system recorded first, for Bouncy.import!.
  #
  # A bounce or a complaint becomes the same evidence that a webhook records, and a manual block
  # becomes a manual hold. The time is the time the other system recorded the block. It is kept
  # as given, however old: config.maximum_event_age is for webhook feedback that arrives late,
  # and an old block that another system kept still stops mail.
  #
  # An import is not new evidence, so it calls no hook. It is idempotent: the same address,
  # reason and time a second time writes nothing. It never removes or weakens a block that is
  # in force, and a release recorded at or after its time fences it.
  class Importer
    REASONS = %w[hard_bounce complaint manual].freeze
    FUTURE_SKEW = 5.minutes
    # The attributes that an import can change. A difference in them is a change to record.
    CHANGES = %w[manual_blocked_at manual_note event_blocked_at event_reason last_event_at blocked_at details].freeze

    def call(email, reason:, at:, note:, actor:)
      reason = reason.to_s
      raise ArgumentError, "reason must be :hard_bounce, :complaint or :manual" unless REASONS.include?(reason)

      time = time_of(at)
      exact = email.to_s.strip
      key = Identity.normalize(email)
      dedupe_key = Digest::SHA256.hexdigest(JSON.generate(["import", Bouncy.scope, key, reason, time.iso8601(6)]))
      Store.change(key) do |row|
        next row if Bouncy.events.exists?(dedupe_key: dedupe_key)

        record(row, reason, time, dedupe_key, exact: exact, note: note.to_s.strip.truncate(1000).presence,
                                              actor: actor.to_s.truncate(200))
      end
    end

    private

    def record(row, reason, time, dedupe_key, exact:, note:, actor:)
      was_blocked = row.blocked?
      released_at = fence(row, reason)
      fenced = !released_at.nil? && time <= released_at
      unless fenced
        before = row.attributes.slice(*CHANGES).deep_dup
        reason == "manual" ? hold(row, time, note) : feedback(row, reason, time, exact)
        row.blocked_at = [row.blocked_at, time].compact.min
        return row if row.attributes.slice(*CHANGES) == before

        row.summarize!
      end
      Store.event!("imported", email: row.email, source: "import", occurred_at: time, dedupe_key: dedupe_key, details: {
                     "reason" => reason, "note" => note, "actor" => actor,
                     "ignored_for_policy" => fenced, "became_blocked" => !was_blocked && row.blocked?
                   })
      row
    end

    # A release clears manual holds and records "soft_released_before". A provider release, or a
    # sync that no longer finds webhook evidence, clears it and records released_before. An
    # imported block at or before that time is older than the release, so it changes nothing.
    def fence(row, reason)
      return row.released_before unless reason == "manual"

      Time.iso8601(row.details["soft_released_before"].to_s)
    rescue ArgumentError
      nil
    end

    # Keeps an earlier hold and its support note.
    def hold(row, time, note)
      return if row.manual_blocked_at && row.manual_blocked_at <= time

      row.manual_note = note unless row.manual_blocked_at
      row.manual_blocked_at = time
    end

    # Webhook evidence keeps the time of its newest block and the stronger reason: a complaint
    # outranks a hard bounce, so an imported hard bounce never replaces a complaint.
    def feedback(row, reason, time, exact)
      previous = row.event_reason if row.event_blocked_at
      return if previous == reason && row.event_blocked_at >= time
      return if previous == "complaint" && row.event_blocked_at >= time

      row.event_reason = previous == "complaint" ? "complaint" : reason
      row.event_blocked_at = [row.event_blocked_at, time].compact.max
      row.last_event_at = [row.last_event_at, time].compact.max
      row.details = row.details.except("absence_count").reverse_merge("exact_email" => exact)
    end

    # Microsecond precision, as every supported database stores it, so a second import of the
    # same time compares and deduplicates as equal.
    def time_of(value)
      raise ArgumentError, "at must be a Time" unless value.is_a?(Time) || value.is_a?(DateTime)

      time = value.to_time.utc.floor(6)
      raise ArgumentError, "at must not be in the future" if time > FUTURE_SKEW.from_now

      time
    end
  end
end
