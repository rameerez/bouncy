# frozen_string_literal: true

module Bouncy
  class Event < Record
    self.table_name = "bouncy_events"

    attribute :details, default: -> { {} }

    scope :for, ->(email) { where(email: Identity.normalize(email)) }
    scope :recent, -> { order(occurred_at: :desc, id: :desc) }

    # A transaction callback rather than after_create_commit: Rails runs transaction callbacks
    # in order, after the record callbacks, so this runs after the release of the address lock
    # that Store.change registered first. No hook runs while Bouncy holds an address.
    after_create { Record.current_transaction.after_commit { notify_host } }

    private

    def notify_host
      Bouncy.notify(:after_event, self)
      Bouncy.notify(:after_block, self) if details["became_blocked"]
      Bouncy.notify(:after_release, self) if kind == "release"
    end
  end
end
