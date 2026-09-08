# frozen_string_literal: true

module Bouncy
  class Record < ActiveRecord::Base
    self.abstract_class = true
    self.implicit_order_column = "created_at"

    before_create :assign_string_primary_key

    private

    def assign_string_primary_key
      self.id ||= SecureRandom.uuid if self.class.type_for_attribute(self.class.primary_key).type == :string
    end
  end
end
