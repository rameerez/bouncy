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
  # or the rollback. MySQL named locks and SQLite file locks belong to the connection; Bouncy
  # releases them when the transaction.active_record event reports the end of the outermost
  # transaction. Rails reports it right after the COMMIT or ROLLBACK, before any after_commit or
  # after_rollback callback, so a callback that raises cannot keep a lock.
  #
  # Hooks never run inside a lock: writes release theirs at the commit, before the hooks, and
  # the hooks of a write inside a hold wait until the hold ends.
  module AddressLock
    FileHold = Struct.new(:guard, :file, :mode, :holders)
    FILE_LOCKS = ObjectSpace::WeakKeyMap.new
    DEFERRED = ObjectSpace::WeakKeyMap.new
    GUARD = Mutex.new

    module_function

    def hold(email)
      key = Identity.normalize(email)
      Record.connection_pool.with_connection do |connection|
        settle(connection)
        release = take(connection, key, exclusive: false)
        depth = ActiveSupport::IsolatedExecutionState[:bouncy_holds].to_i
        ActiveSupport::IsolatedExecutionState[:bouncy_holds] = depth + 1
        begin
          yield
        ensure
          ActiveSupport::IsolatedExecutionState[:bouncy_holds] = depth
          begin
            until_transaction_end(connection, release)
          ensure
            run_pending_hooks if depth.zero?
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

    def holding? = ActiveSupport::IsolatedExecutionState[:bouncy_holds].to_i.positive?

    # Runs a hook now, or after the execution's outermost hold when one is open.
    def after_holds(&hook)
      return hook.call unless holding?

      (ActiveSupport::IsolatedExecutionState[:bouncy_pending_hooks] ||= []) << hook
    end

    def run_pending_hooks
      hooks = ActiveSupport::IsolatedExecutionState[:bouncy_pending_hooks]
      ActiveSupport::IsolatedExecutionState[:bouncy_pending_hooks] = nil
      hooks&.each(&:call)
    end

    # Releases what an ended transaction left behind, in case Rails never reported its end.
    def settle(connection)
      return if connection.transaction_open?

      release_deferred(connection)
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
  # the transaction starts, so a later subscription would miss the transaction that needs it.
  ActiveSupport::Notifications.subscribe("transaction.active_record") { |*, payload| AddressLock.transaction_ended(payload) }
end
