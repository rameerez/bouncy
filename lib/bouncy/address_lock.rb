# frozen_string_literal: true

require "tmpdir"

module Bouncy
  # One lock per address, between the app's senders and Bouncy's own writes.
  #
  # A sender takes the shared side with Bouncy.hold, around its own check and its send. Every
  # Bouncy write to an address (webhook, sync, block!, release!) takes the exclusive side first,
  # until its transaction ends. A new block therefore commits before the sender's check or after
  # its send, never between them. Inside a transaction, a hold lasts until that transaction ends.
  #
  # PostgreSQL holds transaction-level advisory locks, which it releases itself at the commit
  # or the rollback. MySQL named locks and SQLite file locks belong to the connection, and three
  # paths release them at the end of the outermost transaction:
  #
  # 1. the transaction.active_record event, which Rails sends right after the COMMIT or the
  #    ROLLBACK and before any callback, so a host callback that raises cannot keep a lock;
  # 2. after_commit and after_rollback on the transaction itself, for a transaction that started
  #    before Bouncy subscribed to that event;
  # 3. the connection's return to the pool, for anything both paths missed.
  #
  # Hooks never run inside a lock: they wait for the commit of the outermost transaction, which
  # comes after the releases, and the hooks of a write inside a hold wait until the hold ends.
  module AddressLock
    FileHold = Struct.new(:guard, :file, :mode, :holders)
    # Per connection, like the locks themselves: threads that share one connection, as Rails
    # system tests do, share its holds and the hooks that wait for them.
    Holds = Struct.new(:depth, :hooks)
    FILE_LOCKS = ObjectSpace::WeakKeyMap.new
    DEFERRED = ObjectSpace::WeakKeyMap.new
    HOLDS = ObjectSpace::WeakKeyMap.new
    FIXTURES = ObjectSpace::WeakKeyMap.new
    GUARD = Mutex.new

    module_function

    def hold(email)
      key = Identity.normalize(email)
      Record.connection_pool.with_connection do |connection|
        settle(connection)
        require_read_committed(connection)
        release = take(connection, key, exclusive: false)
        holds = GUARD.synchronize { (HOLDS[connection] ||= Holds.new(0, [])).tap { |state| state.depth += 1 } }
        begin
          yield
        ensure
          hooks = GUARD.synchronize do
            holds.depth -= 1
            holds.depth.zero? ? holds.hooks.slice!(0..) : []
          end
          begin
            until_transaction_end(connection, release)
          ensure
            hooks.each(&:call)
          end
        end
      end
    end

    # Takes the exclusive side until the current transaction commits or rolls back. Store.change
    # calls it first in its transaction, before it takes any row lock.
    def claim!(email)
      key = Identity.normalize(email)
      Record.connection_pool.with_connection do |connection|
        until_transaction_end(connection, take(connection, key, exclusive: true))
      end
    end

    def holding?(connection = Record.connection_pool.active_connection)
      connection && GUARD.synchronize { HOLDS[connection]&.depth.to_i.positive? }
    end

    # Runs a hook once its connection holds no Bouncy lock. A record's commit callbacks can run
    # while an outer transaction is still open, under transaction(joinable: false); the hook then
    # moves to that transaction, and so runs after the commit of the outermost one, or never if
    # it rolls back. Inside a hold it waits for the hold.
    #
    # Rails transactional tests keep 0.1's timing: the hook runs at the commit inside the
    # fixture transaction, which only ever rolls back. FixtureTransactions marks that transaction. With no transaction left open, releases
    # that Rails did not report are settled first, because Rails runs record commit callbacks,
    # such as the event's, before the transaction callbacks that would release them.
    def after_locks(&hook)
      connection = Record.connection_pool.active_connection
      return hook.call unless connection

      deferred = connection.transaction_open? && !only_fixture_transaction?(connection)
      return connection.current_transaction.after_commit { after_locks(&hook) } if deferred

      settle(connection)
      queued = GUARD.synchronize do
        holds = HOLDS[connection]
        holds.hooks << hook if holds&.depth.to_i.positive?
      end
      hook.call unless queued
    end

    # True while the connection's only open transaction is the one Rails transactional fixtures
    # began on it. FixtureTransactions records that transaction from the fixture lifecycle.
    def only_fixture_transaction?(connection)
      fixture = GUARD.synchronize { FIXTURES[connection] }
      !fixture.nil? && connection.open_transactions == 1 && connection.current_transaction.equal?(fixture)
    end

    # Prepended into every class that includes ActiveRecord::TestFixtures. Rails 7.2, 8.0 and 8.1
    # enroll a pool into the fixture transactions in two places: setup_transactional_fixtures,
    # for the pools already connected, and its own "!connection.active_record" subscriber, for a
    # pool established or replaced later in the test. Both pin the pool's connection, which
    # begins the fixture transaction, lease that connection and add the pool to
    # @fixture_connection_pools. Rails 8.1 leaves out the pools a test excludes with
    # skip_transactional_tests_for_database. Bouncy marks the transactions of exactly the
    # pools on that list, at setup and from a subscriber that runs after Rails' own, and clears
    # the marks at teardown.
    module FixtureTransactions
      private

      def setup_transactional_fixtures
        super
        @bouncy_fixture_connections = []
        mark_fixture_transactions
        @bouncy_fixture_subscriber = ActiveSupport::Notifications.subscribe("!connection.active_record") { mark_fixture_transactions }
      end

      def teardown_transactional_fixtures
        ActiveSupport::Notifications.unsubscribe(@bouncy_fixture_subscriber) if @bouncy_fixture_subscriber
        Array(@bouncy_fixture_connections).each { |connection| GUARD.synchronize { FIXTURES.delete(connection) } }
        @bouncy_fixture_connections = @bouncy_fixture_subscriber = nil
        super
      end

      def mark_fixture_transactions
        Array(@fixture_connection_pools).each do |pool|
          connection = pool.active_connection
          next if connection.nil? || !connection.transaction_open? || @bouncy_fixture_connections.include?(connection)

          GUARD.synchronize { FIXTURES[connection] = connection.current_transaction }
          @bouncy_fixture_connections << connection
        end
      end
    end

    # Releases what an ended transaction left behind, in case Rails never reported its end.
    def settle(connection)
      return if connection.transaction_open?

      release_deferred(connection)
    end

    # Inside a PostgreSQL transaction, a hold must not run at REPEATABLE READ or SERIALIZABLE:
    # the lock statement fixes the snapshot before it waits, so a block committed during the wait
    # stays invisible. Hold the address outside the transaction instead; the lock then lasts for
    # the whole block, and the transaction's snapshot starts after it.
    def require_read_committed(connection)
      return unless connection.adapter_name == "PostgreSQL" && connection.transaction_open?

      isolation = connection.uncached { connection.select_value("SHOW transaction_isolation") }
      return if ["read committed", "read uncommitted"].include?(isolation)

      raise ConfigurationError, "Bouncy.hold inside a PostgreSQL #{isolation} transaction cannot see a block committed while it waits; " \
                                "call Bouncy.hold outside the transaction, around it"
    end

    # Takes the lock now and returns what releases it, or nil when the database releases it.
    def take(connection, key, exclusive:)
      case connection.adapter_name
      when "PostgreSQL" then take_advisory(connection, key, exclusive)
      when /Mysql|Trilogy/i then take_named(connection, key)
      when "SQLite" then take_file(connection, exclusive ? File::LOCK_EX : File::LOCK_SH)
      else raise ConfigurationError, "Bouncy supports PostgreSQL, MySQL and SQLite"
      end
    end

    # Inside a transaction: a transaction-level lock, released by PostgreSQL at the commit or
    # the rollback, also when a failed statement aborted the transaction. Outside one: a session
    # lock for the block. The key is a signed 64-bit hash of the scope and the address.
    def take_advisory(connection, key, exclusive)
      shared = exclusive ? "" : "_shared"
      if connection.transaction_open?
        connection.execute("SELECT pg_advisory_xact_lock#{shared}(#{advisory_key(key)})")
        return
      end

      connection.execute("SELECT pg_advisory_lock#{shared}(#{advisory_key(key)})")
      -> { connection.execute("SELECT pg_advisory_unlock#{shared}(#{advisory_key(key)})") }
    end

    # GET_LOCK waits as long as an InnoDB row lock would. A session can take the same name again;
    # each take needs its own release. Both statements skip the query cache: a cached GET_LOCK
    # would answer 1 without locking.
    def take_named(connection, key)
      name = connection.quote(Digest::SHA256.hexdigest("bouncy:address:#{connection.pool.db_config.database}:#{Bouncy.scope}:#{key}"))
      acquired = connection.uncached { connection.select_value("SELECT GET_LOCK(#{name}, @@innodb_lock_wait_timeout)") }
      raise ActiveRecord::LockWaitTimeout, "Bouncy could not lock an address in time" unless acquired.to_i == 1

      released = false
      lambda do
        next if released

        released = true
        connection.uncached { connection.select_value("SELECT RELEASE_LOCK(#{name})") }
      rescue ActiveRecord::ActiveRecordError
        # A broken connection ends its session, and the server releases the session's locks.
        nil
      end
    end

    # One file per database, held per connection the way PostgreSQL and MySQL hold a lock per
    # session. A connection that already holds the file reuses its handle: a write inside its
    # own hold upgrades the lock to exclusive instead of waiting for itself. Threads that share
    # one connection, as Rails tests do, share its lock too.
    def take_file(connection, mode)
      held = GUARD.synchronize { FILE_LOCKS[connection] ||= FileHold.new(Mutex.new, nil, nil, 0) }
      held.guard.synchronize do
        if held.file.nil?
          # The handle stays open while the lock is held; the last release closes it.
          file = File.open(lock_path(connection), File::RDWR | File::CREAT, 0o600) # rubocop:disable Style/FileOpen
          file.flock(mode)
          held.file = file
          held.mode = mode
        elsif mode == File::LOCK_EX && held.mode == File::LOCK_SH
          held.file.flock(File::LOCK_EX)
          held.mode = File::LOCK_EX
        end
        held.holders += 1
      end
      released = false
      lambda do
        held.guard.synchronize do
          next if released

          released = true
          held.holders -= 1
          next if held.holders.positive?

          held.file.close
          held.file = held.mode = nil
        end
      end
    end

    def lock_path(connection)
      database = connection.pool.db_config.database
      return File.join(Dir.tmpdir, "bouncy-#{Process.pid}-addresses.lock") if database == ":memory:"

      "#{File.expand_path(database)}.bouncy-addresses.lock"
    end

    # Releases now outside a transaction. Inside one, keeps the release for the end of the
    # outermost transaction; the transaction is materialized first, so Rails reports its end.
    def until_transaction_end(connection, release)
      return unless release
      return release.call unless connection.transaction_open?

      connection.materialize_transactions
      GUARD.synchronize { (DEFERRED[connection] ||= []) << release }
      watch(connection)
    end

    # The second path. A savepoint under a joinable parent hands both callbacks to the parent
    # when it commits. One that rolls back, or commits under a transaction(joinable: false)
    # parent, runs its callback while the parent continues, so the watch moves up a level. It
    # uses the connection's transaction object: the public Record.current_transaction is a null
    # transaction under transaction(joinable: false), and would run the block at once.
    def watch(connection)
      transaction = connection.current_transaction
      ended = -> { connection.transaction_open? ? watch(connection) : settle(connection) }
      transaction.after_commit(&ended)
      transaction.after_rollback(&ended)
    end

    # Rails pops a committed transaction before it reports the commit, and reports a rollback
    # before it pops the transaction. :restart reports a savepoint that continues.
    def transaction_ended(payload)
      connection = payload[:connection]
      return unless connection && GUARD.synchronize { DEFERRED.key?(connection) }

      outermost = case payload[:outcome]
                  when :commit then connection.open_transactions.zero?
                  when :rollback then connection.open_transactions <= 1
                  when :incomplete then true
                  else false
                  end
      release_deferred(connection) if outermost
    end

    def release_deferred(connection)
      releases = GUARD.synchronize { DEFERRED.delete(connection) }
      releases&.each(&:call)
    end

    def advisory_key(key) = Digest::SHA256.digest("bouncy:address\n#{Bouncy.scope}\n#{key}").unpack1("q>")
  end

  # Subscribed when the gem loads: Rails gives each transaction the subscribers that exist when
  # the transaction starts, so a later subscription misses it, and the second path covers that.
  ActiveSupport::Notifications.subscribe("transaction.active_record") { |*, payload| AddressLock.transaction_ended(payload) }

  ActiveSupport.on_load(:active_record_fixtures) { prepend AddressLock::FixtureTransactions }

  # The third path: a connection goes back to the pool with nothing of Bouncy's still locked.
  ActiveRecord::ConnectionAdapters::AbstractAdapter.set_callback(:checkin, :after) { AddressLock.release_deferred(self) }
end
