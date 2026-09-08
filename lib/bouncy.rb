# frozen_string_literal: true

require "rails"
require "active_record"
require "active_support/all"
require "digest"
require "json"
require "time"
require_relative "bouncy/version"

module Bouncy
  class Error < StandardError; end
  class InvalidAddress < Error; end
  class ConfigurationError < Error; end
  class ProviderError < Error; end

  class ReleaseFailed < ProviderError
    attr_reader :outcomes

    def initialize(message, outcomes:)
      @outcomes = outcomes
      super(message)
    end
  end

  class UnsafeSnapshot < ProviderError; end
  class ReleaseConflict < Error; end
  class AuthenticationError < Error; end
  class MalformedMessage < Error; end

  DATABASE_UNAVAILABLE = [ActiveRecord::ConnectionNotEstablished, ActiveRecord::ConnectionTimeoutError].freeze

  class << self
    def configuration = (@configuration ||= Configuration.new)

    def configure
      yield configuration
    end

    def reset_configuration!
      @warned_unconfigured = false
      @configuration = Configuration.new
    end

    def scope = configuration.validate!.scope
    def adapter = configuration.adapter || Providers::Ses.new(configuration)

    # True when config.scope is set. An unconfigured Bouncy is inactive: it intercepts nothing,
    # reports no restrictions and returns empty relations, so a host can install the gem before
    # its environment variables exist without breaking mail delivery. Explicit operations
    # (sync!, block!, release!, forget!) still raise ConfigurationError.
    def configured? = configuration.configured?

    def unconfigured!(operation)
      ActiveSupport::Notifications.instrument("unconfigured.bouncy", operation: operation)
      return if @warned_unconfigured

      @warned_unconfigured = true
      Rails.logger&.warn("[bouncy] config.scope is not set, so Bouncy is inactive: no interception, no restrictions, no sync. " \
                         "Set it in config/initializers/bouncy.rb.")
      nil
    end

    def blocked = configured? ? Suppression.where(scope: scope).blocked : Suppression.none
    def events = configured? ? Event.where(scope: scope) : Event.none
    def last_sync = events.where(kind: "sync").order(created_at: :desc, id: :desc).first

    def sync_fresh?(sync = last_sync)
      !!(configured? && sync && sync.scope == scope && sync.details["complete"] && sync.created_at >= configuration.stale_after.ago)
    end

    def bootstrap!
      sync! unless sync_fresh?
      raise UnsafeSnapshot, "Bootstrap requires a fresh complete sync with verified sending policy; run bouncy:doctor" unless sync_fresh?

      last_sync
    end

    def last_successful_sync = events.where(kind: "sync").order(created_at: :desc, id: :desc).detect { |event| event.details["complete"] }

    def status(email)
      unless configured?
        unconfigured!("status")
        return Status.new(nil, knowledge: :unconfigured)
      end

      Status.new(Suppression.find_by(scope: scope, email: Identity.normalize(email)))
    rescue ActiveRecord::ActiveRecordError => e
      raise unless database_unavailable?(e)

      Status.new(nil, knowledge: :unavailable)
    end

    def blocked?(email) = status(email).blocked?
    def sync! = Reconciler.new(adapter).call
    def release!(email, note: nil, actor: nil, at: :provider) = Recovery.new(adapter).call(email, note: note, actor: actor, at: at)

    def block!(email, note:, actor: nil)
      raise ArgumentError, "A support note is required" if note.to_s.strip.empty?

      Store.change(email) do |row|
        was_blocked = row.blocked?
        row.manual_blocked_at ||= Time.current
        row.manual_note = note.to_s.truncate(1000)
        row.summarize!
        Store.event!("manual_block", email: row.email, details: {
                       "note" => row.manual_note, "actor" => actor.to_s.truncate(200), "became_blocked" => !was_blocked
                     })
        row
      end
    end

    def forget!(email)
      current_scope = scope
      key = Identity.normalize(email)
      Suppression.transaction do
        Event.where(scope: current_scope, email: key).delete_all
        Suppression.where(scope: current_scope, email: key).delete_all
      end
    end

    def unblocked
      previous = ActiveSupport::IsolatedExecutionState[:bouncy_unblocked]
      ActiveSupport::IsolatedExecutionState[:bouncy_unblocked] = true
      yield
    ensure
      ActiveSupport::IsolatedExecutionState[:bouncy_unblocked] = previous
    end

    def notify(hook, event)
      configuration.public_send(hook).call(event)
    rescue StandardError => e
      ActiveSupport::Notifications.instrument("hook_error.bouncy", hook: hook, error_class: e.class.name)
    end

    def database_unavailable?(error)
      DATABASE_UNAVAILABLE.any? { |type| error.is_a?(type) } ||
        %w[PG::ConnectionBad PG::UnableToSend SQLite3::CantOpenException].include?(error.cause&.class&.name)
    end
  end
end

require_relative "bouncy/configuration"
require_relative "bouncy/identity"
require_relative "bouncy/record"
require_relative "bouncy/suppression"
require_relative "bouncy/event"
require_relative "bouncy/status"
require_relative "bouncy/store"
require_relative "bouncy/providers/base"
require_relative "bouncy/providers/ses"
require_relative "bouncy/providers/ses_parser"
require_relative "bouncy/ingestor"
require_relative "bouncy/recovery"
require_relative "bouncy/scope_lock"
require_relative "bouncy/reconciler"
require_relative "bouncy/model"
require_relative "bouncy/interceptor"
require_relative "bouncy/webhook"
require_relative "bouncy/sync_job"
require_relative "bouncy/prune_job"
require_relative "bouncy/engine"
