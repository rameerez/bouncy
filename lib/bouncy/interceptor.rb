# frozen_string_literal: true

module Bouncy
  class Interceptor
    def self.delivering_email(message)
      return if Bouncy.configuration.interception == :off || ActiveSupport::IsolatedExecutionState[:bouncy_unblocked]
      return Bouncy.unconfigured!("interception") unless Bouncy.configured?

      new.call(message)
    end

    def call(message)
      envelope = Array(message.smtp_envelope_to).dup
      headers = %i[to cc bcc].to_h { |field| [field, Array(message.public_send(field)).dup] }
      keys = (envelope + headers.values.flatten).filter_map { |email| normalize(email) }.uniq
      rows = Bouncy.blocked.where(email: keys).to_a
      return if rows.empty?

      mode = Bouncy.configuration.interception
      # Provider-derived evidence is only enforced while a complete sync is fresh. Manual holds
      # and legacy soft holds are local policy and do not depend on provider freshness. The same
      # rule applies in :log mode so that its preview matches what :drop would do.
      health = Bouncy.last_sync
      fresh = health && health.details["complete"] && health.created_at >= Bouncy.configuration.stale_after.ago
      enforceable = rows.select { |row| fresh || row.manual_blocked_at || (row.soft_blocked_until && row.soft_blocked_until > Time.current) }
      blocked = enforceable.map(&:email)
      remaining = envelope.reject { |email| blocked.include?(normalize(email)) }
      changed_headers = headers.transform_values { |values| values.reject { |email| blocked.include?(normalize(email)) } }
      # Persist all skip evidence before changing the message. A DB outage must leave it intact.
      Event.transaction do
        rows.each do |row|
          would_drop = enforceable.include?(row)
          Store.event!("skipped", email: row.email, source: "interceptor", details: {
                         "mode" => mode.to_s, "reasons" => row.reasons.map(&:to_s), "would_drop" => would_drop,
                         "dropped" => mode == :drop && would_drop, "stale_provider_evidence" => !would_drop
                       })
        end
      end
      return unless mode == :drop && blocked.any?

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
