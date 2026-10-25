# frozen_string_literal: true

require "test_helper"
require "active_record/fixtures"

# A host's own test suite runs inside Rails transactional fixtures. Their transaction only rolls
# back, so Bouncy's hooks keep 0.1's timing there: they run when the app's transaction commits
# inside it, as Rails runs after_commit callbacks in such tests.
class TransactionalFixturesTest < ActiveSupport::TestCase
  include ActiveRecord::TestFixtures

  self.use_transactional_tests = true

  # Earlier tests leave rows behind; a blocked row would make block! report no new block.
  def setup
    super
    Bouncy::Event.delete_all
    Bouncy::Suppression.delete_all
    Bouncy.reset_configuration!
    Bouncy.configuration.scope = "ses:123456789012:us-east-1:account"
    Bouncy.configuration.adapter = FakeProvider.new
  end

  test "hooks fire inside transactional fixtures, at the commit of the app's own transaction" do
    connection = ActiveRecord::Base.connection
    assert connection.pinned, "Rails pinned the connection for the fixture transaction"
    assert_equal 1, connection.open_transactions

    blocked = []
    events = []
    Bouncy.configuration.after_block = ->(event) { blocked << event.email }
    Bouncy.configuration.after_event = ->(event) { events << event.kind }

    Bouncy.block!("ana@example.com", note: "Hold")
    assert_equal ["ana@example.com"], blocked
    ActiveRecord::Base.transaction do
      Bouncy.block!("bea@example.com", note: "Hold")
      assert_equal ["ana@example.com"], blocked, "the app's transaction has not committed yet"
    end
    assert_equal %w[ana@example.com bea@example.com], blocked
    assert_equal %w[manual_block manual_block], events
    Bouncy.hold("cleo@example.com") { Bouncy.block!("cleo@example.com", note: "Hold") }
    assert_equal "cleo@example.com", blocked.last
  end

  test "a non-joinable transaction of the app inside the fixtures still defers its hooks" do
    blocked = []
    Bouncy.configuration.after_block = ->(event) { blocked << event.email }
    ActiveRecord::Base.transaction(joinable: false) do
      Bouncy.block!("ana@example.com", note: "Hold")
      assert_empty blocked
    end
    assert_equal ["ana@example.com"], blocked
  end
end
