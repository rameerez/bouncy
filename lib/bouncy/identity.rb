# frozen_string_literal: true

module Bouncy
  module Identity
    module_function

    def normalize(email)
      raise InvalidAddress, "Email addresses cannot contain control characters" if email.to_s.match?(/[\x00-\x1f\x7f]/)

      value = email.to_s.strip
      unless value.bytesize <= 254 && value.match?(/\A[^\s@<>\x00-\x1f\x7f]+@[^\s@<>\x00-\x1f\x7f]+\z/)
        raise InvalidAddress, "Provide a nonblank email address without control characters"
      end

      value.downcase
    end
  end
end
