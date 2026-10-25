# frozen_string_literal: true

require "test_helper"
require "active_record/fixtures"

# A host's own test suite runs inside Rails transactional fixtures. Their transaction only rolls
# back, so Bouncy's hooks keep 0.1's timing there: they run when the app's transaction commits
# inside it, as Rails runs after_commit callbacks in such tests.
class TransactionalFixturesTest < ActiveSupport::TestCase
  include ActiveRecord::TestFixtures

  self.use_transactional_tests = true

  # Earlier tests leave rows behind; a blocked row would make block! report no new block. The
  # rows go before the fixture transaction begins: on MySQL a delete inside it would keep its
  # next-key locks, and a second pool could not insert until the rollback.
  def before_setup
    Bouncy::Event.delete_all
    Bouncy::Suppression.delete_all
    super
  end

  def setup
    super
    Bouncy.reset_configuration!
    Bouncy.configuration.scope = "ses:123456789012:us-east-1:account"
    Bouncy.configuration.adapter = FakeProvider.new
  end

  test "hooks fire inside transactional fixtures, at the commit of the app's own transaction" do
    connection = ActiveRecord::Base.connection
    assert_equal 1, connection.open_transactions
    assert_same connection.current_transaction, Bouncy::AddressLock::FIXTURES[connection], "the fixture lifecycle marked its transaction"

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

  # Removes the pool a test gave Bouncy's models, once Rails rolled its fixture transaction back.
  def after_teardown
    super
  ensure
    Bouncy::Record.remove_connection if @own_pool
  end

  test "a pool established during the test is enrolled, and its hooks fire when the app's transaction commits" do
    skip "an in-memory SQLite database exists only on its first connection" if ActiveRecord::Base.connection_db_config.database == ":memory:"

    Bouncy::Record.establish_connection(ActiveRecord::Base.connection_db_config)
    @own_pool = true
    connection = Bouncy::Record.connection
    refute_same ActiveRecord::Base.connection, connection, "Bouncy's models have a pool of their own"
    assert_equal 1, connection.open_transactions, "Rails began a fixture transaction on the new pool"
    assert_same connection.current_transaction, Bouncy::AddressLock::FIXTURES[connection]

    address = "late-#{SecureRandom.hex(4)}@example.com"
    blocked = []
    Bouncy.configuration.after_block = ->(event) { blocked << event.email }
    Bouncy::Record.transaction do
      Bouncy.block!(address, note: "Hold")
      assert_empty blocked
    end
    assert_equal [address], blocked
  end

  test "a hook of another thread on the shared fixture connection waits for this thread's hold" do
    blocked = []
    Bouncy.configuration.after_block = ->(event) { blocked << event.email }
    Bouncy.hold("ana@example.com") do
      Thread.new { Bouncy.block!("bea@example.com", note: "Hold") }.join(5)
      assert Bouncy.blocked?("bea@example.com"), "the other thread used the same connection"
      assert_empty blocked, "the hold on the shared connection is still open"
    end
    assert_equal ["bea@example.com"], blocked
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

if ActiveRecord::TestFixtures::ClassMethods.method_defined?(:skip_transactional_tests_for_database)
  # Rails 8.1 lets a test leave a database out of the fixture transactions. A transaction the
  # host opens there is the host's own: Bouncy must not give it fixture timing.
  class ExcludedDatabaseFixturesTest < ActiveSupport::TestCase
    include ActiveRecord::TestFixtures

    self.use_transactional_tests = true
    skip_transactional_tests_for_database(:primary)

    # Opened before the fixtures set up, as a host's own override would.
    def before_setup
      ActiveRecord::Base.connection.begin_transaction(joinable: false)
      super
    end

    def setup
      super
      Bouncy.reset_configuration!
      Bouncy.configuration.scope = "ses:123456789012:us-east-1:account"
      Bouncy.configuration.adapter = FakeProvider.new
    end

    def after_teardown
      super
    ensure
      connection = ActiveRecord::Base.connection
      connection.rollback_transaction while connection.transaction_open?
    end

    test "an excluded pool gets no fixture timing, and its rollback drops the hooks" do
      connection = ActiveRecord::Base.connection
      assert_equal 1, connection.open_transactions, "only the host's own transaction is open"
      assert_nil Bouncy::AddressLock::FIXTURES[connection]

      address = "excluded-#{SecureRandom.hex(4)}@example.com"
      blocked = []
      Bouncy.configuration.after_block = ->(event) { blocked << event.email }
      Bouncy.block!(address, note: "Hold")
      assert_empty blocked, "the hook waits for the host's transaction"
      connection.rollback_transaction
      assert_empty blocked, "the rollback dropped it"
      refute Bouncy.blocked?(address)
    end
  end
end
