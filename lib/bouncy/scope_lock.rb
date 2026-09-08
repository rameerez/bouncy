# frozen_string_literal: true

require "tmpdir"

module Bouncy
  module ScopeLock
    module_function

    def synchronize
      Record.connection_pool.with_connection do |connection|
        key = Digest::SHA256.hexdigest(Bouncy.scope)[0, 15].to_i(16)
        case connection.adapter_name
        when "PostgreSQL"
          connection.execute("SELECT pg_advisory_lock(#{key})")
          begin
            yield
          ensure
            connection.execute("SELECT pg_advisory_unlock(#{key})")
          end
        when /Mysql|Trilogy/i
          name = Digest::SHA256.hexdigest("bouncy:#{connection.pool.db_config.database}:#{Bouncy.scope}")
          acquired = connection.select_value("SELECT GET_LOCK('#{name}', 5)")
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
            file.flock(File::LOCK_EX)
            yield
          ensure
            file.flock(File::LOCK_UN)
          end
        else
          raise ConfigurationError, "Bouncy supports PostgreSQL, MySQL and SQLite"
        end
      end
    end
  end
end
