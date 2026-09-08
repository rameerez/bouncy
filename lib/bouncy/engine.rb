# frozen_string_literal: true

module Bouncy
  class Engine < Rails::Engine
    isolate_namespace Bouncy

    initializer "bouncy.model" do
      ActiveSupport.on_load(:active_record) { extend Bouncy::Model }
    end

    initializer "bouncy.interceptor" do
      ActiveSupport.on_load(:action_mailer) { register_interceptor Bouncy::Interceptor }
    end
  end
end
