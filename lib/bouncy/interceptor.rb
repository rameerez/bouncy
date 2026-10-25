# frozen_string_literal: true

module Bouncy
  # Checks the recipients of every mail where Mail hands it to the transport.
  #
  # Mail calls delivering_email before each delivery. It stamps the configuration-set header and
  # wraps the message's delivery method in a Gate. Mail's deliver and deliver! both end in that
  # delivery method, after every interceptor and every Action Mailer callback, so the Gate
  # decides on the recipients the transport would really get. In :drop mode it removes blocked
  # recipients, and when none is left it does not call the transport: deliver_now!,
  # deliver_later! and their plain forms all send nothing.
  class Interceptor
    CONFIGURATION_SET_HEADER = "X-SES-CONFIGURATION-SET"
    RECIPIENT_FIELDS = %i[to cc bcc].freeze

    # The delivery method of a message that Bouncy checks. Mail builds it through
    # Message#delivery_method(Gate, transport), its public way to set a delivery method.
    class Gate
      attr_reader :transport

      def initialize(transport)
        @transport = transport
      end

      def settings = transport.settings

      # Bypass, scope and mode are read again at each delivery: a message delivered once keeps
      # its gate, and can be delivered again under Bouncy.unblocked or another mode.
      def deliver!(message)
        return transport.deliver!(message) unless Interceptor.active?
        return if Interceptor.new.call(message) == :undeliverable

        transport.deliver!(message)
      end

      def respond_to_missing?(name, include_private = false) = transport.respond_to?(name, include_private) || super
      def method_missing(name, ...) = transport.respond_to?(name) ? transport.public_send(name, ...) : super
    end

    class << self
      def delivering_email(message)
        stamp_configuration_set(message)
        return if bypassed?
        return Bouncy.unconfigured!("interception") unless Bouncy.configured?

        transport = message.delivery_method
        message.delivery_method(Gate, transport) unless transport.is_a?(Gate)
      end

      def active? = !bypassed? && Bouncy.configured?

      private

      def bypassed? = Bouncy.configuration.interception == :off || ActiveSupport::IsolatedExecutionState[:bouncy_unblocked]

      # SES reads the set from this header and removes it before delivery. A mail that names its
      # own set keeps it. The header does not depend on the interception mode: turning
      # interception off must not stop the events that SES publishes for the set.
      def stamp_configuration_set(message)
        name = Bouncy.configuration.ses.configuration_set.presence
        message[CONFIGURATION_SET_HEADER] = name if name && message.header[CONFIGURATION_SET_HEADER].nil?
      end
    end

    # Returns :undeliverable when :drop removed every recipient, else nil.
    def call(message)
      envelope = Array(message.smtp_envelope_to).dup
      fields = RECIPIENT_FIELDS.to_h { |name| [name, addresses(message[name])] }
      keys = (envelope + fields.values.flatten.map(&:address)).filter_map { |entry| normalize(entry) }.uniq
      rows = Bouncy.current_state(Bouncy.blocked).where(email: keys).to_a
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
