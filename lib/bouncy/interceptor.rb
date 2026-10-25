# frozen_string_literal: true

module Bouncy
  # Checks the recipients of every mail before it goes out.
  #
  # Action Mailer's before_deliver callback runs the check first (deliverable?). When :drop
  # leaves no recipient, the callback halts the delivery: deliver_now!, deliver_later! and their
  # plain forms all stop, although Mail's bang delivery ignores perform_deliveries. Mail then
  # calls the interceptor (delivering_email). It stamps the configuration-set header and checks
  # again only a mail sent through Mail directly, or one whose recipients changed since.
  class Interceptor
    CONFIGURATION_SET_HEADER = "X-SES-CONFIGURATION-SET"
    RECIPIENT_FIELDS = %i[to cc bcc].freeze

    class << self
      def delivering_email(message)
        stamp_configuration_set(message)
        checked = message.instance_variable_get(:@bouncy_recipients)
        message.instance_variable_set(:@bouncy_recipients, nil)
        intercept(message) unless checked && checked == recipients_of(message)
      end

      # False when :drop removed every recipient, so the callback halts the delivery.
      def deliverable?(message)
        return false if intercept(message) == :undeliverable

        message.instance_variable_set(:@bouncy_recipients, recipients_of(message))
        true
      end

      private

      def intercept(message)
        return if Bouncy.configuration.interception == :off || ActiveSupport::IsolatedExecutionState[:bouncy_unblocked]
        return Bouncy.unconfigured!("interception") unless Bouncy.configured?

        new.call(message)
      end

      # SES reads the set from this header and removes it before delivery. A mail that names its
      # own set keeps it. The header does not depend on the interception mode: turning
      # interception off must not stop the events that SES publishes for the set.
      def stamp_configuration_set(message)
        name = Bouncy.configuration.ses.configuration_set.presence
        message[CONFIGURATION_SET_HEADER] = name if name && message.header[CONFIGURATION_SET_HEADER].nil?
      end

      def recipients_of(message)
        [Array(message.smtp_envelope_to), *RECIPIENT_FIELDS.map { |field| message[field].to_s }]
      end
    end

    # Returns :undeliverable when :drop removed every recipient, else nil.
    def call(message)
      envelope = Array(message.smtp_envelope_to).dup
      fields = RECIPIENT_FIELDS.to_h { |name| [name, addresses(message[name])] }
      keys = (envelope + fields.values.flatten.map(&:address)).filter_map { |entry| normalize(entry) }.uniq
      rows = Bouncy.blocked.where(email: keys).to_a
      return if rows.empty?

      mode = Bouncy.configuration.interception
      # Provider-derived evidence is only enforced while a complete sync is fresh, unless the host
      # set require_fresh_sync to false. Manual holds and legacy soft holds are local policy and
      # do not depend on provider freshness. The same rule applies in :log mode so that its
      # preview matches what :drop would do.
      fresh = !Bouncy.configuration.require_fresh_sync || Bouncy.sync_fresh?
      enforceable = rows.select { |row| fresh || row.manual_blocked_at || (row.soft_blocked_until && row.soft_blocked_until > Time.current) }
      blocked = enforceable.map(&:email)
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

      # Each kept entry keeps its own text, display name included; only the lookup uses the
      # bare address.
      fields.each do |name, field_addresses|
        kept = field_addresses.reject { |address| blocked.include?(normalize(address.address)) }
        message[name] = kept.empty? ? nil : kept.map(&:format) if kept.size < field_addresses.size
      end
      remaining = envelope.reject { |entry| blocked.include?(normalize(entry)) }
      message.smtp_envelope_to = remaining
      return if remaining.any?

      message.perform_deliveries = false
      :undeliverable
    rescue ActiveRecord::ActiveRecordError => e
      raise unless Bouncy.database_unavailable?(e)

      ActiveSupport::Notifications.instrument("unavailable.bouncy", operation: "interception")
      nil
    end

    private

    # The parsed addresses of a To, Cc or Bcc field, or none for a field Mail cannot parse.
    def addresses(field)
      field.respond_to?(:addrs) ? field.addrs : []
    end

    # "Ada <ADA@example.com>" and "ada@example.com" are the same lookup key.
    def normalize(value)
      Identity.normalize(Mail::Address.new(value.to_s).address)
    rescue InvalidAddress, Mail::Field::ParseError
      nil
    end
  end
end
