# frozen_string_literal: true

require "tmpdir"

module Bouncy
  # One reconciliation per scope at a time. Every adapter fails fast: a second caller gets
  # ProviderError immediately instead of queueing behind a run that may be waiting on AWS.
  module ScopeLock
    module_function

    def synchronize
      Record.connection_pool.with_connection do |connection|
        key = Digest::SHA256.hexdigest(Bouncy.scope)[0, 15].to_i(16)
        case connection.adapter_name
        when "PostgreSQL"
          acquired = connection.select_value("SELECT pg_try_advisory_lock(#{key})")
          raise ProviderError, "Another sync holds this scope lock" unless [true, "t"].include?(acquired)

          begin
            yield
          ensure
            connection.execute("SELECT pg_advisory_unlock(#{key})")
          end
        when /Mysql|Trilogy/i
          name = Digest::SHA256.hexdigest("bouncy:#{connection.pool.db_config.database}:#{Bouncy.scope}")
          acquired = connection.select_value("SELECT GET_LOCK('#{name}', 0)")
          raise ProviderError, "Another sync holds this scope lock" unless acquired == 1

          begin
            yield
          ensure
            connection.execute("SELECT RELEASE_LOCK('#{name}')")
          end
        when "SQLite"
          database = connection.pool.db_config.database
          path = database == ":memory:" ? File.join(Dir.tmpdir, "bouncy-#{Process.pid}-#{key}.lock") : "#{File.expand_path(database)}.bouncy-#{key}.lock"
          File.open(path, File::RDWR | File::CREAT, 0o600) do |file|
            raise ProviderError, "Another sync holds this scope lock" unless file.flock(File::LOCK_EX | File::LOCK_NB)

            begin
              yield
            ensure
              file.flock(File::LOCK_UN)
            end
          end
        else
          raise ConfigurationError, "Bouncy supports PostgreSQL, MySQL and SQLite"
        end
      end
    end
  end
end
