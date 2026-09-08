# frozen_string_literal: true

require "simplecov"
SimpleCov.start

ENV["RAILS_ENV"] = "test"
require "bouncy"
require "rails/generators"
require "action_mailer/railtie"
require "minitest/autorun"
require "minitest/mock"
require "minitest/reporters"
require "active_support/test_case"
require "active_support/testing/time_helpers"
require "webmock/minitest"
require "tmpdir"

WebMock.disable_net_connect!
Minitest::Reporters.use! [Minitest::Reporters::SpecReporter.new]

class TestApplication < Rails::Application
  config.eager_load = false
  config.secret_key_base = "test-secret" * 10
  config.logger = Logger.new(File::NULL)
  config.active_support.deprecation = :stderr
  config.action_mailer.delivery_method = :test
  config.action_mailer.perform_deliveries = true
  config.active_job.queue_adapter = :test
end

TestApplication.initialize!
Rails.configuration.generators.orm :active_record, primary_key_type: ENV["BOUNCY_TEST_PRIMARY_KEY"]&.to_sym

ActiveRecord::Base.establish_connection(ENV.fetch("DATABASE_URL", "sqlite3::memory:"))
database = ActiveRecord::Base.connection_db_config.database
abort "Tests require an isolated database named bouncy_test*" unless database == ":memory:" || File.basename(database).start_with?("bouncy_test")
require "generators/bouncy/install_generator"
generator = Bouncy::Generators::InstallGenerator.new
template = File.read(File.expand_path("../lib/generators/bouncy/templates/create_bouncy_tables.rb.erb", __dir__))
# Execute the repository's generated migration, never an independently maintained test schema.
eval(ERB.new(template).result(generator.instance_eval { binding }), TOPLEVEL_BINDING, "create_bouncy_tables.rb") # rubocop:disable Security/Eval
ActiveRecord::Migration.verbose = false
CreateBouncyTables.migrate(:down) if ActiveRecord::Base.connection.table_exists?(:bouncy_events)
CreateBouncyTables.migrate(:up)
ActiveRecord::Schema.define do
  create_table :contacts, force: true do |table|
    table.string :email
    table.string :billing_email
    table.string :canonical_email
  end
end

class FakeProvider < Bouncy::Providers::Base
  attr_accessor :entries, :complete, :policy_verified, :on_snapshot, :on_release, :scope
  attr_reader :deleted, :lookups

  def initialize
    super
    @entries = []
    @complete = @policy_verified = true
    @deleted = []
    @lookups = []
  end

  def snapshot
    started_at = Time.current
    copy = entries.dup
    on_snapshot&.call
    Bouncy::Providers::Snapshot.new(entries: copy, scope: scope || Bouncy.scope, complete: complete,
                                    policy_verified: policy_verified, started_at: started_at, finished_at: Time.current)
  end

  def lookup(email)
    @lookups << email
    entries.any? { |entry| entry.email == email } ? :present : :absent
  end

  def release(targets)
    targets.each do |entry|
      @deleted << entry.email
      entries.reject! { |candidate| candidate.email == entry.email }
    end
    on_release&.call
  end
end

class BouncyTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::TimeHelpers

  def setup
    Bouncy::Event.delete_all
    Bouncy::Suppression.delete_all
    ActiveRecord::Base.connection.execute("DELETE FROM contacts")
    Bouncy.reset_configuration!
    Bouncy.configuration.scope = "ses:123456789012:us-east-1:account"
    @provider = FakeProvider.new
    Bouncy.configuration.adapter = @provider
  end

  def entry(email = "Ada@Example.com", reason: :hard_bounce, time: 1.day.ago)
    Bouncy::Providers::Entry.new(email: email, reason: reason, updated_at: time)
  end

  def observe(email = "ada@example.com", kind: "hard_bounce", id: SecureRandom.uuid, time: Time.current, details: {})
    Bouncy::Ingestor.new.call(Bouncy::Observation.new(email: email, kind: kind, provider_event_id: id,
                                                      message_id: "message-1", occurred_at: time, details: details,
                                                      provider_reason: nil, status_code: nil, diagnostic: nil))
  end
end
