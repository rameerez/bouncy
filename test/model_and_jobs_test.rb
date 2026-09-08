# frozen_string_literal: true

require "test_helper"

class Contact < ActiveRecord::Base
  bouncy :email, :billing_email
end

class CanonicalContact < ActiveRecord::Base
  self.table_name = "contacts"
  bouncy :email, normalized_attribute: :canonical_email
end

class ModelAndJobsTest < BouncyTest
  test "macro predicates and scopes agree for canonical stored attributes" do
    ada = Contact.create!(email: "ada@example.com", billing_email: "billing@example.com")
    ben = Contact.create!(email: "ben@example.com")
    Contact.create!(email: nil)
    Contact.create!(email: "")
    observe
    assert ada.email_blocked?
    assert ada.email_bounced?
    refute ada.email_complained?
    refute ada.billing_email_blocked?
    assert_equal [ada], Contact.email_blocked.to_a
    assert_equal [ada], Contact.email_bounced.to_a
    assert_equal [ben], Contact.email_unblocked.to_a
    observe(kind: "complaint", details: { "certainty" => "confirmed" })
    assert ada.email_complained?
  end

  test "custom persisted canonical attribute supports mixed case display value" do
    contact = CanonicalContact.create!(email: "Ada@Example.com", canonical_email: "ada@example.com")
    observe
    assert contact.email_blocked?
    assert_equal [contact], CanonicalContact.email_blocked.to_a
  end

  test "macro rejects ambiguous declarations without boot queries" do
    assert_raises(ArgumentError) { Class.new(ActiveRecord::Base).bouncy }
    assert_raises(ArgumentError) { Class.new(ActiveRecord::Base).bouncy(:email, :billing_email, normalized_attribute: :canonical) }
  end

  test "jobs sync and prune only configured events while retaining release fences" do
    @provider.entries = [entry]
    Bouncy::SyncJob.perform_now
    assert Bouncy.last_sync
    assert Bouncy.last_successful_sync
    Bouncy.release!("ada@example.com", note: "Recovery")
    Bouncy.events.update_all(created_at: 91.days.ago)
    Bouncy::PruneJob.perform_now
    assert_empty Bouncy.events
    assert Bouncy::Suppression.first.released_before
    refute Bouncy.blocked?("ada@example.com")
  end

  test "configuration rejects unsafe retention and invalid interception" do
    Bouncy.configuration.scope = nil
    assert_raises(Bouncy::ConfigurationError) { Bouncy.scope }
    Bouncy.configuration.scope = "a" * 192
    assert_raises(Bouncy::ConfigurationError) { Bouncy.scope }
    Bouncy.configuration.scope = "test"
    Bouncy.configuration.adapter = nil
    Bouncy.configuration.provider = :other
    assert_raises(Bouncy::ConfigurationError) { Bouncy.scope }
    Bouncy.configuration.provider = :ses
    Bouncy.configuration.interception = :silent
    assert_raises(Bouncy::ConfigurationError) { Bouncy.scope }
    Bouncy.configuration.interception = :log
    Bouncy.configuration.retention = 1.day
    assert_raises(Bouncy::ConfigurationError) { Bouncy.scope }
  end
end
