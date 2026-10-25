# frozen_string_literal: true

require "active_job"

module Bouncy
  class SyncJob < ActiveJob::Base
    queue_as :default

    # A recurring job in an app that has not set config.scope does nothing, instead of failing
    # every run. Bouncy.sync! itself still raises.
    def perform
      return Rails.logger&.info("[bouncy] Bouncy::SyncJob skipped: config.scope is not set") unless Bouncy.configured?

      Bouncy.sync!
    end
  end
end
