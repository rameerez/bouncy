# frozen_string_literal: true

module Bouncy
  module Providers
    Entry = Data.define(:email, :reason, :updated_at) do
      def to_h
        { "email" => email, "reason" => reason.to_s, "provider_updated_at" => updated_at.iso8601(6) }
      end
    end

    # The result of reading a provider list. A scan that streamed its pages returns no entries
    # here; incomplete_reason says why a scan stopped before the end of the list.
    Snapshot = Data.define(:entries, :scope, :complete, :policy_verified, :started_at, :finished_at, :policy_reason,
                           :incomplete_reason) do
      def initialize(policy_reason: nil, incomplete_reason: nil, **members) = super
    end

    # One page of a scan, handed to the caller as soon as it is read. authoritative: an exact
    # identifier that the address had before and that this page does not list may be dropped
    # once a direct lookup confirms that it is absent. observed_at: when the page was read.
    Page = Data.define(:entries, :scope, :authoritative, :policy_verified, :observed_at)

    # Total work one scan may do. Past any limit the scan stops and reports itself incomplete,
    # so its pages still add restrictions but nothing is cleared for being absent from it.
    class DeadlineExceeded < StandardError; end

    # A monotonic deadline shared by the local scan, provider scan and absence pass.
    class Deadline
      def self.now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      def initialize(duration)
        @duration = duration
        @expires_at = self.class.now + duration
      end

      def check!
        raise DeadlineExceeded, "time limit (#{@duration.to_i}s) reached" if self.class.now >= @expires_at
      end
    end

    Limits = Data.define(:pages, :entries, :duration, :deadline) do
      def initialize(deadline: nil, **members) = super

      def exceeded(pages:, entries:)
        return "page limit (#{self.pages}) reached" if pages >= self.pages

        "entry limit (#{self.entries}) reached" if entries >= self.entries
      end
    end

    # Result of the sending-policy check: verified, or the plain-language reason it is not.
    PolicyCheck = Data.define(:verified, :reason)

    class Base
      def snapshot = raise(NotImplementedError)
      def lookup(_entry) = raise(NotImplementedError)
      def release(_entries) = raise(NotImplementedError)

      # Yields the provider list one Page at a time and returns the Snapshot that says whether
      # the list was read to the end. An adapter that can page overrides this to keep only one
      # page in memory and to honour the limits; this default reads the whole snapshot and
      # yields it as one page, as 0.2.2 did.
      def scan(limits = nil)
        limits&.deadline&.check!
        snapshot = self.snapshot
        limits&.deadline&.check!
        yield Page.new(entries: snapshot.entries, scope: snapshot.scope, authoritative: snapshot.complete,
                       policy_verified: snapshot.policy_verified, observed_at: snapshot.finished_at)
        limits&.deadline&.check!
        snapshot
      end
    end
  end
end
