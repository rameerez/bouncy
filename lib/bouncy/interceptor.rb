# frozen_string_literal: true

module Bouncy
  class Interceptor
    def self.delivering_email(message)
      return if Bouncy.configuration.interception == :off || ActiveSupport::IsolatedExecutionState[:bouncy_unblocked]

      new.call(message)
    end

    def call(message)
      envelope = Array(message.smtp_envelope_to).dup
      headers = %i[to cc bcc].to_h { |field| [field, Array(message.public_send(field)).dup] }
      keys = (envelope + headers.values.flatten).filter_map { |email| normalize(email) }.uniq
      rows = Bouncy.blocked.where(email: keys).to_a
      return if rows.empty?

      drop = Bouncy.configuration.interception == :drop
      if drop
        health = Bouncy.last_sync
        fresh = health && health.details["complete"] && health.created_at >= Bouncy.configuration.stale_after.ago
        rows.select! { |row| fresh || row.manual_blocked_at || (row.soft_blocked_until && row.soft_blocked_until > Time.current) }
      end
      blocked = rows.map(&:email)
      remaining = envelope.reject { |email| blocked.include?(normalize(email)) }
      changed_headers = headers.transform_values { |values| values.reject { |email| blocked.include?(normalize(email)) } }
      # Persist all skip evidence before changing the message. A DB outage must leave it intact.
      Event.transaction do
        rows.each do |row|
          Store.event!("skipped", email: row.email, source: "interceptor", details: {
                         "mode" => Bouncy.configuration.interception.to_s, "reasons" => row.reasons.map(&:to_s), "would_drop" => !drop
                       })
        end
      end
      return unless drop && blocked.any?

      changed_headers.each { |field, values| message.public_send("#{field}=", values.empty? ? nil : values) }
      message.smtp_envelope_to = remaining
      message.perform_deliveries = false if remaining.empty?
    rescue ActiveRecord::ActiveRecordError => e
      raise unless Bouncy.database_unavailable?(e)

      ActiveSupport::Notifications.instrument("unavailable.bouncy", operation: "interception")
    end

    private

    def normalize(value)
      Identity.normalize(Mail::Address.new(value).address)
    rescue InvalidAddress, Mail::Field::ParseError
      nil
    end
  end
end
