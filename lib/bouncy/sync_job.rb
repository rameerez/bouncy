# frozen_string_literal: true

require "active_job"

module Bouncy
  class SyncJob < ActiveJob::Base
    queue_as :default

    def perform
      Bouncy.sync!
    end
  end
end
