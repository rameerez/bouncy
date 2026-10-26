# frozen_string_literal: true

module Bouncy
  # Names the database family of a connection, which decides the lock Bouncy takes. A subclass
  # of a Rails adapter belongs to the family of its parent class: the PostGIS adapter is a
  # PostgreSQLAdapter whose adapter_name is "PostGIS", and the Trilogy and Mysql2 adapters share
  # AbstractMysqlAdapter. The adapter_name is the fallback for an adapter that only renames
  # itself. Each class is looked up only once its adapter is loaded, so no driver gem loads.
  module Database
    FAMILIES = {
      postgresql: ["PostgreSQLAdapter", /postg/i],
      mysql: ["AbstractMysqlAdapter", /mysql|trilogy/i],
      sqlite: ["SQLite3Adapter", /sqlite/i]
    }.freeze

    module_function

    # :postgresql, :mysql, :sqlite, or nil for any other database.
    def family(connection)
      FAMILIES.find { |_, (adapter, _)| subclass?(connection, adapter) }&.first ||
        FAMILIES.find { |_, (_, name)| connection.adapter_name.match?(name) }&.first
    end

    def family!(connection)
      family(connection) || raise(ConfigurationError, "Bouncy supports PostgreSQL, MySQL and SQLite")
    end

    def subclass?(connection, adapter)
      ActiveRecord::ConnectionAdapters.const_defined?(adapter, false) &&
        connection.is_a?(ActiveRecord::ConnectionAdapters.const_get(adapter, false))
    end
  end
end
