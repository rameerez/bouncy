# frozen_string_literal: true

module Bouncy
  class Engine < Rails::Engine
    isolate_namespace Bouncy

    initializer "bouncy.model" do
      ActiveSupport.on_load(:active_record) { extend Bouncy::Model }
    end

    initializer "bouncy.interceptor" do
      ActiveSupport.on_load(:action_mailer) do
        register_interceptor Bouncy::Interceptor
        # Mail's bang delivery ignores perform_deliveries, so a mail with no recipient left
        # must stop here, before Mail runs: this halts deliver_now! and deliver_later! too.
        before_deliver { |mailer| throw :abort unless Bouncy::Interceptor.deliverable?(mailer.message) }
      end
    end
  end
end
