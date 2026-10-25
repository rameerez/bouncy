# frozen_string_literal: true

require "test_helper"
require "timeout"

class HoldMailer < ActionMailer::Base
  def notice(to)
    mail(from: "sender@example.com", to: to, subject: "Notice", body: "Hello")
  end
end

# Bouncy.hold: the call shape of a sender that checks the address and sends in one step.
class HoldTest < BouncyTest
  def setup
    super
    ActionMailer::Base.deliveries.clear
  end

  test "hold runs the block once and returns its value" do
    calls = 0
    assert_equal :sent, Bouncy.hold("Ada@Example.com") { calls += 1 and :sent }
    assert_equal 1, calls
  end

  test "hold needs a block and a valid address" do
    assert_raises(ArgumentError) { Bouncy.hold("ada@example.com") }
    assert_raises(Bouncy::InvalidAddress) { Bouncy.hold("not an address") { flunk "the block must not run" } }
  end

  test "an unconfigured Bouncy runs the block without a lock" do
    Bouncy.configuration.scope = nil
    operations = []
    subscriber = ActiveSupport::Notifications.subscribe("unconfigured.bouncy") { |*args| operations << args.last[:operation] }
    assert_equal :sent, Bouncy.hold("ada@example.com") { :sent }
    assert_equal ["hold"], operations
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  test "a write inside the execution's own hold, and a nested hold, do not wait for themselves" do
    Timeout.timeout(5) do
      Bouncy.hold("ada@example.com") do
        Bouncy.hold("ada@example.com") { Bouncy.block!("ada@example.com", note: "Hold") }
        Bouncy::Suppression.transaction { Bouncy.hold("ben@example.com") { Bouncy.block!("ben@example.com", note: "Hold") } }
      end
    end
    assert Bouncy.blocked?("ada@example.com")
    assert Bouncy.blocked?("ben@example.com")
  end

  test "the hold ends when the block raises, and a later write goes through" do
    assert_raises(RuntimeError) { Bouncy.hold("ada@example.com") { raise "the send failed" } }
    assert_raises(RuntimeError) do
      Bouncy::Suppression.transaction { Bouncy.hold("ada@example.com") { raise "the send failed" } }
    end
    Timeout.timeout(5) { Bouncy.block!("ada@example.com", note: "Hold") }
    assert Bouncy.blocked?("ada@example.com")
  end

  test "a check and a send inside the hold see the same state" do
    Bouncy.configuration.interception = :drop
    Bouncy.block!("ada@example.com", note: "Hold")
    sent = Bouncy.hold("ada@example.com") do
      HoldMailer.notice("ada@example.com").deliver_now unless Bouncy.blocked?("ada@example.com")
    end
    assert_nil sent
    assert_empty ActionMailer::Base.deliveries
  end
end

# SQLite has one writer at a time: the hold is a shared lock on one file beside the database,
# and every Bouncy write takes it exclusive until its transaction ends.
class SqliteHoldTest < BouncyTest
  def with_file_database
    connection = ActiveRecord::Base.connection
    Dir.mktmpdir("bouncy-hold") do |directory|
      path = File.join(directory, "app.sqlite3")
      connection.pool.db_config.stub(:database, path) do
        connection.stub(:adapter_name, "SQLite") { yield "#{path}.bouncy-addresses.lock" }
      end
    end
  end

  def lockable?(path, mode)
    File.open(path, File::RDWR | File::CREAT) { |file| file.flock(mode | File::LOCK_NB) != false }
  end

  test "a hold is shared, a write is exclusive, and both end with the block or the transaction" do
    with_file_database do |path|
      Bouncy.hold("ada@example.com") do
        assert lockable?(path, File::LOCK_SH), "another sender does not wait"
        refute lockable?(path, File::LOCK_EX), "a write waits"
      end
      assert lockable?(path, File::LOCK_EX)

      Bouncy::Suppression.transaction do
        Bouncy.hold("ada@example.com") { :sent }
        refute lockable?(path, File::LOCK_EX), "inside a transaction the hold lasts until it ends"
      end
      assert lockable?(path, File::LOCK_EX)

      Bouncy::Store.change("ada@example.com") { refute lockable?(path, File::LOCK_SH), "a write excludes senders" }
      assert lockable?(path, File::LOCK_SH)

      Bouncy::Store.change("ada@example.com") { raise ActiveRecord::Rollback }
      assert lockable?(path, File::LOCK_EX), "a rollback ends the write's lock"
    end
  end

  test "hooks run after the write released the address" do
    with_file_database do |path|
      seen = []
      Bouncy.configuration.after_block = ->(_event) { seen << lockable?(path, File::LOCK_EX) }
      Bouncy.configuration.after_event = ->(_event) { seen << lockable?(path, File::LOCK_EX) }
      Bouncy.block!("ada@example.com", note: "Hold")
      Bouncy::Suppression.transaction { observe("ben@example.com") }
      assert_equal [true] * 4, seen
    end
  end

  test "a release runs once, whichever transaction callback calls it" do
    with_file_database do |path|
      connection = ActiveRecord::Base.connection
      release = Bouncy::AddressLock.acquire(connection, "ada@example.com", exclusive: false)
      refute lockable?(path, File::LOCK_EX)
      2.times { release.call }
      assert lockable?(path, File::LOCK_EX)
      assert_nil Bouncy::AddressLock::FILE_LOCKS[connection].file
    end
  end

  test "threads that share one connection share its lock, as a database session would" do
    with_file_database do |path|
      connection = ActiveRecord::Base.connection
      release = Bouncy::AddressLock.acquire(connection, "ada@example.com", exclusive: true)
      other = Thread.new { Bouncy::AddressLock.acquire(connection, "ada@example.com", exclusive: false).call }
      assert other.join(5), "a thread on the same connection does not wait for that connection"
      refute lockable?(path, File::LOCK_SH)
      release.call
      assert lockable?(path, File::LOCK_EX)
    end
  end

  test "a memory database uses a lock file of its own process" do
    connection = ActiveRecord::Base.connection
    connection.pool.db_config.stub(:database, ":memory:") do
      connection.stub(:adapter_name, "SQLite") do
        Bouncy.hold("ada@example.com") { assert File.exist?(File.join(Dir.tmpdir, "bouncy-#{Process.pid}-addresses.lock")) }
      end
    end
  end

  test "an unsupported database is refused" do
    connection = ActiveRecord::Base.connection
    connection.stub(:adapter_name, "Unsupported") do
      assert_raises(Bouncy::ConfigurationError) { Bouncy.hold("ada@example.com") { flunk "the block must not run" } }
    end
  end
end

if ActiveRecord::Base.connection.adapter_name.match?(/PostgreSQL|Mysql|Trilogy/)
  # The lock commits for real across connections, so these tests use threads with their own
  # connections. Each read skips the query cache.
  class HoldConcurrencyTest < BouncyTest
    def setup
      super
      ActionMailer::Base.deliveries.clear
    end

    def teardown
      @threads&.each { |thread| thread.join(5) }
      super
    end

    def in_thread(&)
      (@threads ||= []) << Thread.new { ActiveRecord::Base.connection_pool.with_connection(&) }
      @threads.last
    end

    def blocked?(email) = Bouncy::Suppression.uncached { Bouncy.blocked?(email) }

    test "a write waits while a sender holds the address, and does not wait for another address" do
      holding = Queue.new
      done = Queue.new
      in_thread { Bouncy.hold("ana@example.com") { holding << true and done.pop } }
      holding.pop

      Timeout.timeout(5) { Bouncy.block!("bea@example.com", note: "Hold") }
      assert blocked?("bea@example.com"), "another address does not wait"

      write = in_thread { Bouncy.block!("ana@example.com", note: "Hold") }
      assert_nil write.join(0.5), "the write waits while the sender holds the address"
      refute blocked?("ana@example.com")

      done << true
      assert write.join(5)
      assert blocked?("ana@example.com")
    ensure
      done << true
    end

    test "inside a transaction the hold lasts until the transaction commits" do
      held = Queue.new
      commit = Queue.new
      in_thread do
        Bouncy::Suppression.transaction do
          Bouncy.hold("ana@example.com") { :sent }
          held << true
          commit.pop
        end
      end
      held.pop

      write = in_thread { Bouncy.block!("ana@example.com", note: "Hold") }
      assert_nil write.join(0.5), "the block has returned, but its transaction has not ended"
      commit << true
      assert write.join(5)
      assert blocked?("ana@example.com")
    ensure
      commit << true
    end

    test "a block from the webhook cannot land between a sender's check and its send" do
      Bouncy.configuration.interception = :drop
      Bouncy.configuration.require_fresh_sync = false
      checked = Queue.new
      send = Queue.new
      sender = in_thread do
        Bouncy.hold("ana@example.com") do
          next :skipped if Bouncy.blocked?("ana@example.com")

          checked << true
          send.pop
          HoldMailer.notice("ana@example.com").deliver_now
          :sent
        end
      end
      checked.pop

      webhook = in_thread { observe("ana@example.com") }
      assert_nil webhook.join(0.5), "the bounce waits for the send"
      send << true
      assert_equal :sent, sender.value
      assert_equal ["ana@example.com"], ActionMailer::Base.deliveries.sole.to, "the interceptor saw the state the sender checked"
      assert_equal :accepted, webhook.value
      assert blocked?("ana@example.com")
    ensure
      send << true
    end

    test "a failed statement inside a held transaction leaves no lock behind" do
      in_thread do
        Bouncy::Suppression.transaction do
          Bouncy.hold("ana@example.com") do
            Bouncy::Suppression.connection.execute("SELECT * FROM bouncy_missing_table")
          rescue ActiveRecord::StatementInvalid
            nil
          end
          raise ActiveRecord::Rollback
        end
      end.join(5)
      write = in_thread { Bouncy.block!("ana@example.com", note: "Hold") }
      assert write.join(5), "the connection went back to the pool without the address lock"
      assert blocked?("ana@example.com")
    end

    if ActiveRecord::Base.connection.adapter_name.match?(/Mysql|Trilogy/)
      test "a named lock is released once, whichever transaction callback calls it" do
        connection = ActiveRecord::Base.connection
        2.times { Bouncy::AddressLock.acquire(connection, "ana@example.com", exclusive: false) } # one session takes it twice
        release = Bouncy::AddressLock.acquire(connection, "ana@example.com", exclusive: false)
        2.times { release.call }
        write = in_thread { Bouncy.block!("ana@example.com", note: "Hold") }
        assert_nil write.join(0.3), "two takes remain, and a second call of one release did not end them"
        name = Digest::SHA256.hexdigest("bouncy:address:#{connection.pool.db_config.database}:#{Bouncy.scope}:ana@example.com")
        2.times { connection.select_value("SELECT RELEASE_LOCK('#{name}')") }
        assert write.join(5)
      end
    end

    if ActiveRecord::Base.connection.adapter_name == "PostgreSQL"
      test "on PostgreSQL senders to one address do not wait for each other" do
        holding = Queue.new
        done = Queue.new
        in_thread { Bouncy.hold("ana@example.com") { holding << true and done.pop } }
        holding.pop
        other = in_thread { Bouncy.hold("ana@example.com") { :sent } }
        assert_equal :sent, Timeout.timeout(5) { other.value }
      ensure
        done << true
      end
    else
      test "on MySQL senders to one address take turns" do
        holding = Queue.new
        done = Queue.new
        in_thread { Bouncy.hold("ana@example.com") { holding << true and done.pop } }
        holding.pop
        other = in_thread { Bouncy.hold("ana@example.com") { :sent } }
        assert_nil other.join(0.3)
        done << true
        assert_equal :sent, Timeout.timeout(5) { other.value }
      ensure
        done << true
      end
    end
  end
end
