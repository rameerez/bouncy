# frozen_string_literal: true

module Bouncy
  class PruneJob < ActiveJob::Base
    queue_as :default

    def perform
      Bouncy.configuration.validate!
      # Keep state rows, including inactive release fences, indefinitely.
      Bouncy.events.where("created_at < ?", Bouncy.configuration.retention.ago).in_batches.delete_all
    end
  end
end
