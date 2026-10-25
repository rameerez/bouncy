# frozen_string_literal: true

require "tmpdir"

module Bouncy
  # One lock per address, between the app's senders and Bouncy's own writes.
  #
  # A sender takes the shared side with Bouncy.hold, around its own check and its send. Every
  # Bouncy write to an address (webhook, sync, block!, release!) takes the exclusive side first,
  # until its transaction ends. A new block therefore commits before the sender's check or after
  # its send, never between them. Inside a transaction, a hold also lasts until that transaction
  # ends, so it covers the commit that records the send.
  #
  # PostgreSQL uses advisory locks, and senders to one address do not wait for each other.
  # MySQL's named locks have no shared mode, so there senders to one address take turns. SQLite
  # has one writer at a time, and uses one shared or exclusive file lock beside the database.
  module AddressLock
    # PostgreSQL's two-key form, so these keys stay apart from an app's one-key advisory locks
    # and from Bouncy's scope lock.
    NAMESPACE = 0x626f756e # "boun"

    FileHold = Struct.new(:guard, :file, :mode, :holders)
    FILE_LOCKS = ObjectSpace::WeakKeyMap.new
    FILE_LOCKS_GUARD = Mutex.new

    module_function

    def hold(email, &)
      key = Identity.normalize(email)
      Record.connection_pool.with_connection do |connection|
        if postgresql?(connection)
          hold_advisory(connection, key, &)
        else
          release = acquire(connection, key, exclusive: false)
          begin
            yield
          ensure
            at_transaction_end(&release)
          end
        end
      end
    end

    # Takes the exclusive side until the current transaction commits or rolls back. Store.change
    # calls it first in its transaction, before it takes any row lock.
    def claim!(email)
      key = Identity.normalize(email)
      Record.connection_pool.with_connection do |connection|
        if postgresql?(connection)
          connection.execute("SELECT pg_advisory_xact_lock(#{NAMESPACE}, #{advisory_key(key)})")
        else
          at_transaction_end(&acquire(connection, key, exclusive: true))
        end
      end
    end

    # A transaction-level lock inside a transaction: PostgreSQL releases it at the commit or the
    # rollback, also when a failed statement aborted the transaction. Outside a transaction, a
    # session lock for the block.
    def hold_advisory(connection, key)
      arguments = "#{NAMESPACE}, #{advisory_key(key)}"
      if connection.transaction_open?
        connection.execute("SELECT pg_advisory_xact_lock_shared(#{arguments})")
        return yield
      end

      connection.execute("SELECT pg_advisory_lock_shared(#{arguments})")
      begin
        yield
      ensure
        connection.execute("SELECT pg_advisory_unlock_shared(#{arguments})")
      end
    end

    # Takes the MySQL or SQLite lock now and returns the block that releases it.
    def acquire(connection, key, exclusive:)
      case connection.adapter_name
      when /Mysql|Trilogy/i then acquire_named(connection, key)
      when "SQLite" then acquire_file(connection, exclusive ? File::LOCK_EX : File::LOCK_SH)
      else raise ConfigurationError, "Bouncy supports PostgreSQL, MySQL and SQLite"
      end
    end

    # GET_LOCK waits as long as an InnoDB row lock would. A session can take the same name again;
    # each take needs its own release.
    def acquire_named(connection, key)
      name = connection.quote(Digest::SHA256.hexdigest("bouncy:address:#{connection.pool.db_config.database}:#{Bouncy.scope}:#{key}"))
      acquired = connection.select_value("SELECT GET_LOCK(#{name}, @@innodb_lock_wait_timeout)")
      raise ActiveRecord::LockWaitTimeout, "Bouncy could not lock an address in time" unless acquired.to_i == 1

      released = false
      lambda do
        next if released

        released = true
        connection.select_value("SELECT RELEASE_LOCK(#{name})")
      rescue ActiveRecord::ActiveRecordError
        # A broken connection ends its session, and the server releases the session's locks.
        nil
      end
    end

    # One file per database, held per connection the way PostgreSQL and MySQL hold a lock per
    # session. A connection that already holds the file reuses its handle: a write inside its
    # own hold upgrades the lock to exclusive instead of waiting for itself. Threads that share
    # one connection, as Rails tests do, share its lock too.
    def acquire_file(connection, mode)
      held = FILE_LOCKS_GUARD.synchronize { FILE_LOCKS[connection] ||= FileHold.new(Mutex.new, nil, nil, 0) }
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

    # Runs the block when the current transaction commits or rolls back, or now when no
    # transaction is open. A savepoint that commits hands both callbacks to its parent.
    def at_transaction_end(&)
      transaction = Record.current_transaction
      transaction.after_commit(&)
      transaction.after_rollback(&)
    end

    def advisory_key(key) = Digest::SHA256.hexdigest("#{Bouncy.scope}\n#{key}")[0, 7].to_i(16)
    def postgresql?(connection) = connection.adapter_name == "PostgreSQL"
  end
end
