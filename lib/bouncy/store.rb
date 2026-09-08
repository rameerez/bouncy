# frozen_string_literal: true

module Bouncy
  module Store
    module_function

    # Retry outside the transaction: PostgreSQL aborts a transaction on a unique violation.
    def change(email)
      key = Identity.normalize(email)
      attempts = 0
      begin
        Suppression.transaction(requires_new: true) do
          row = Suppression.find_or_create_by!(scope: Bouncy.scope, email: key) do |record|
            record.provider = Bouncy.configuration.provider.to_s
          end
          row.with_lock { yield row }
        end
      rescue ActiveRecord::RecordNotUnique, ActiveRecord::StaleObjectError, ActiveRecord::Deadlocked
        attempts += 1
        retry if attempts < 3
        raise
      end
    end

    def event!(kind, email: nil, source: "admin", occurred_at: Time.current, **attributes)
      Event.create!({ scope: Bouncy.scope, email: email, kind: kind, source: source,
                      received_at: Time.current, occurred_at: occurred_at }.merge(attributes))
    end
  end
end
