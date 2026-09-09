# frozen_string_literal: true

module Bouncy
  # Statuses for many addresses, loaded with one query by Bouncy.statuses. Look an address
  # up by any spelling; an address that was not asked for, or that is not a valid address,
  # answers with a plain no-known-block status. When Bouncy is unconfigured or the database
  # is unavailable every lookup answers with that knowledge instead.
  class StatusSet
    include Enumerable

    def initialize(statuses, knowledge: nil)
      @statuses = statuses
      @knowledge = knowledge
    end

    def [](email)
      key = begin
        Identity.normalize(email)
      rescue InvalidAddress
        nil
      end
      (key && @statuses[key]) || Status.new(nil, knowledge: @knowledge)
    end

    # Yields [normalized_email, status] pairs for the addresses that were asked for.
    def each(&) = @statuses.each(&)
    def size = @statuses.size
    def blocked = @statuses.select { |_email, status| status.blocked? }
    def to_h = @statuses.dup
  end
end
