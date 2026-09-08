# frozen_string_literal: true

Bouncy::Engine.routes.draw do
  post "/webhooks/ses", to: Bouncy::Webhook.new
end
