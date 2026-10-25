# frozen_string_literal: true

module Bouncy
  class Event < Record
    self.table_name = "bouncy_events"

    attribute :details, default: -> { {} }

    scope :for, ->(email) { where(email: Identity.normalize(email)) }
    scope :recent, -> { order(occurred_at: :desc, id: :desc) }

    # An import is not new evidence, so it calls no hook.
    after_create_commit :notify_host, unless: -> { kind == "imported" }

    private

    # Writes release their address locks at the commit of the outermost transaction, and the
    # hooks wait for that commit and for the end of any Bouncy.hold, so no hook runs while
    # Bouncy holds an address.
    def notify_host
      AddressLock.after_locks do
        Bouncy.notify(:after_event, self)
        Bouncy.notify(:after_block, self) if details["became_blocked"]
        Bouncy.notify(:after_release, self) if kind == "release"
      end
    end
  end
end
