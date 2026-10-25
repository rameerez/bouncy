# frozen_string_literal: true

module Bouncy
  class PruneJob < ActiveJob::Base
    queue_as :default

    # Like SyncJob, a no-op until config.scope is set.
    def perform
      return Rails.logger&.info("[bouncy] Bouncy::PruneJob skipped: config.scope is not set") unless Bouncy.configured?

      Bouncy.configuration.validate!
      # Keep state rows, including inactive release fences, indefinitely.
      Bouncy.events.where("created_at < ?", Bouncy.configuration.retention.ago).in_batches.delete_all
    end
  end
end
