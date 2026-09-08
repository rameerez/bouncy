# frozen_string_literal: true

module Bouncy
  class Suppression < Record
    self.table_name = "bouncy_suppressions"

    attribute :provider_entries, default: -> { [] }
    attribute :details, default: -> { {} }

    scope :blocked, lambda {
      where("manual_blocked_at IS NOT NULL OR provider_blocked_at IS NOT NULL OR event_blocked_at IS NOT NULL OR soft_blocked_until > ?", Time.current)
    }

    def reasons
      values = []
      values << :manual if manual_blocked_at
      values << provider_reason.to_sym if provider_blocked_at && provider_reason
      values << event_reason.to_sym if event_blocked_at && event_reason
      values << :soft_bounces if soft_blocked_until && soft_blocked_until > Time.current
      values.uniq
    end

    def blocked?
      reasons.any?
    end

    def summarize!
      self.reason = (%i[complaint hard_bounce provider_list manual soft_bounces] & reasons).first
      self.blocked_at = blocked? ? (blocked_at || Time.current) : nil
      save!
    end
  end
end
