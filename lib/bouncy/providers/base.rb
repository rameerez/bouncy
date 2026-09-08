# frozen_string_literal: true

module Bouncy
  module Providers
    Entry = Data.define(:email, :reason, :updated_at) do
      def to_h
        { "email" => email, "reason" => reason.to_s, "provider_updated_at" => updated_at.iso8601(6) }
      end
    end

    Snapshot = Data.define(:entries, :scope, :complete, :policy_verified, :started_at, :finished_at, :policy_reason) do
      def initialize(policy_reason: nil, **members) = super
    end

    # Result of the sending-policy check: verified, or the plain-language reason it is not.
    PolicyCheck = Data.define(:verified, :reason)

    class Base
      def snapshot = raise(NotImplementedError)
      def lookup(_entry) = raise(NotImplementedError)
      def release(_entries) = raise(NotImplementedError)
    end
  end
end
