# frozen_string_literal: true

module Bouncy
  class Event < Record
    self.table_name = "bouncy_events"

    attribute :details, default: -> { {} }

    scope :for, ->(email) { where(email: Identity.normalize(email)) }
    scope :recent, -> { order(occurred_at: :desc, id: :desc) }

    after_create_commit :notify_host

    private

    def notify_host
      Bouncy.notify(:after_event, self)
      Bouncy.notify(:after_block, self) if details["became_blocked"]
      Bouncy.notify(:after_release, self) if kind == "release"
    end
  end
end
