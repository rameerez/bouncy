# frozen_string_literal: true

module Bouncy
  module Model
    def bouncy(*attributes, normalized_attribute: nil)
      raise ArgumentError, "Provide an email attribute" if attributes.empty?
      raise ArgumentError, "normalized_attribute supports one email attribute at a time" if normalized_attribute && attributes.size != 1

      attributes.each do |attribute|
        column = normalized_attribute || attribute
        define_method("#{attribute}_status") { Bouncy.status(public_send(column)) }
        define_method("#{attribute}_blocked?") do
          value = public_send(column)
          value.present? && Bouncy.blocked?(value)
        end
        define_method("#{attribute}_bounced?") do
          public_send("#{attribute}_blocked?") && public_send("#{attribute}_status").reasons.intersect?(%i[hard_bounce soft_bounces])
        end
        define_method("#{attribute}_complained?") { public_send("#{attribute}_blocked?") && public_send("#{attribute}_status").reasons.include?(:complaint) }

        scope "#{attribute}_blocked", -> { where(column => Bouncy.blocked.select(:email)) }
        scope "#{attribute}_bounced", lambda {
          rows = Bouncy.blocked.where("provider_reason = ? OR event_reason = ? OR soft_blocked_until > ?", "hard_bounce", "hard_bounce", Time.current)
          where(column => rows.select(:email))
        }
        scope "#{attribute}_unblocked", -> { where.not(column => [nil, ""]).where.not(column => Bouncy.blocked.select(:email)) }
      end
    end
  end
end
