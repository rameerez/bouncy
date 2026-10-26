# frozen_string_literal: true

require "test_helper"
require "support/signed_sns"
require "active_record/connection_adapters/postgresql_adapter"
require "active_record/connection_adapters/abstract_mysql_adapter"
require "active_record/connection_adapters/sqlite3_adapter"

# Adapters that subclass a Rails adapter and report a name of their own, as the PostGIS adapter
# does. The PostGIS and Trilogy stand-ins record their statements and open no connection.
class DatabaseFamilyTest < BouncyTest
  Pool = Struct.new(:connection) do
    def with_connection = yield(connection)
    def active_connection = connection
    def db_config = Struct.new(:database).new("bouncy_test")
  end

  module Recorded
    attr_writer :transaction_open

    def statements = (@statements ||= [])
    def answers = (@answers ||= {})
    def transaction_open? = @transaction_open == true
    def uncached = yield
    def quote(value) = "'#{value}'"
    def pool = Pool.new(self)
    def execute(sql) = statements << sql

    def select_value(sql)
      statements << sql
      answers.find { |pattern, _| sql.match?(pattern) }&.last
    end
  end

  PostGIS = Class.new(ActiveRecord::ConnectionAdapters::PostgreSQLAdapter) do
    include Recorded

    def adapter_name = "PostGIS"
  end

  # Stands in for TrilogyAdapter, which shares AbstractMysqlAdapter with Mysql2Adapter.
  Trilogy = Class.new(ActiveRecord::ConnectionAdapters::AbstractMysqlAdapter) do
    include Recorded

    def adapter_name = "Trilogy"
  end

  RenamedMysql = Class.new(ActiveRecord::ConnectionAdapters::AbstractMysqlAdapter) { def adapter_name = "Renamed" }
  RenamedSqlite = Class.new(ActiveRecord::ConnectionAdapters::SQLite3Adapter) { def adapter_name = "Renamed" }
  NamedOnly = Struct.new(:adapter_name)

  def connect(adapter)
    connection = adapter.allocate
    Bouncy::Record.stub(:connection_pool, Pool.new(connection)) { yield connection }
  end

  def assert_statements(patterns, connection)
    assert_equal patterns.size, connection.statements.size, connection.statements.inspect
    patterns.zip(connection.statements).each { |pattern, sql| assert_match pattern, sql }
  end

  test "a subclass of a Rails adapter keeps its family under any name" do
    assert_equal :postgresql, Bouncy::Database.family(PostGIS.allocate)
    assert_equal :mysql, Bouncy::Database.family(Trilogy.allocate)
    assert_equal :mysql, Bouncy::Database.family(RenamedMysql.allocate)
    assert_equal :sqlite, Bouncy::Database.family(RenamedSqlite.allocate)
  end

  test "an adapter that only renames itself is known by its name, and any other is refused" do
    assert_equal :postgresql, Bouncy::Database.family(NamedOnly.new("PostGIS"))
    assert_equal :postgresql, Bouncy::Database.family(NamedOnly.new("PostgreSQL"))
    assert_equal :mysql, Bouncy::Database.family(NamedOnly.new("Mysql2"))
    assert_equal :mysql, Bouncy::Database.family(NamedOnly.new("Trilogy"))
    assert_equal :sqlite, Bouncy::Database.family(NamedOnly.new("SQLite"))
    assert_nil Bouncy::Database.family(NamedOnly.new("Unsupported"))
    error = assert_raises(Bouncy::ConfigurationError) { Bouncy::Database.family!(NamedOnly.new("Unsupported")) }
    assert_equal "Bouncy supports PostgreSQL, MySQL and SQLite", error.message
  end

  test "a PostGIS adapter takes the PostgreSQL address and scope locks" do
    connect(PostGIS) do |connection|
      connection.answers[/pg_try_advisory_lock/] = true
      assert_equal :sent, Bouncy.hold("ada@example.com") { :sent }
      assert_equal(:synced, Bouncy::ScopeLock.synchronize { :synced })
      assert_statements [/\ASELECT pg_advisory_lock_shared\(-?\d+\)\z/, /\ASELECT pg_advisory_unlock_shared\(-?\d+\)\z/,
                         /\ASELECT pg_try_advisory_lock\(\d+\)\z/, /\ASELECT pg_advisory_unlock\(\d+\)\z/], connection
    end
  end

  test "inside a transaction a PostGIS adapter gets the PostgreSQL isolation check" do
    connect(PostGIS) do |connection|
      connection.transaction_open = true
      connection.answers[/transaction_isolation/] = "repeatable read"
      error = assert_raises(Bouncy::ConfigurationError) { Bouncy.hold("ada@example.com") { flunk "the block must not run" } }
      assert_match(/inside a PostgreSQL repeatable read transaction/, error.message)
      connection.answers[/transaction_isolation/] = "read committed"
      assert_equal :sent, Bouncy.hold("ada@example.com") { :sent }
      assert_match(/\ASELECT pg_advisory_xact_lock_shared\(-?\d+\)\z/, connection.statements.last)
    end
  end

  test "a Trilogy-named MySQL adapter takes named locks and locking reads" do
    connect(Trilogy) do |connection|
      connection.answers[/GET_LOCK/] = 1
      relation = Bouncy.hold("ada@example.com") { Bouncy.current_state(Bouncy::Suppression.all) }
      assert_equal "LOCK IN SHARE MODE", relation.lock_value
      assert_equal(:synced, Bouncy::ScopeLock.synchronize { :synced })
      assert_statements [/\ASELECT GET_LOCK\('\h{64}', @@innodb_lock_wait_timeout\)\z/, /\ASELECT RELEASE_LOCK\('\h{64}'\)\z/,
                         /\ASELECT GET_LOCK\('\h{64}', 0\)\z/, /\ASELECT RELEASE_LOCK\('\h{64}'\)\z/], connection
    end
  end

  test "the migration gives a PostGIS database JSONB and native UUIDs, and a renamed MySQL one binary collation" do
    migration = CreateBouncyTables.new
    [PostGIS.allocate, NamedOnly.new("PostGIS")].each do |connection|
      migration.stub(:connection, connection) do
        assert_equal :jsonb, migration.send(:json_column_type)
        assert_equal({ id: :uuid }, migration.send(:primary_key_options, :uuid))
      end
    end
    [Trilogy.allocate, RenamedMysql.allocate].each do |connection|
      migration.stub(:connection, connection) do
        assert_equal :json, migration.send(:json_column_type)
        assert_equal({ collation: "utf8mb4_bin" }, migration.send(:identity_column_options))
        assert_equal({ null: false }, migration.send(:json_column_options, {}))
      end
    end
    migration.stub(:connection, RenamedSqlite.allocate) do
      assert_equal({ id: :string, limit: 36 }, migration.send(:primary_key_options, :uuid))
      assert_equal({}, migration.send(:identity_column_options))
    end
  end
end

# The suite's own connection under another name, as the PostGIS adapter names a PostgreSQL one:
# the receiver, the hold and the sync work exactly as under the adapter's own name.
class RenamedConnectionTest < BouncyTest
  include SignedSns

  def rename(&)
    connection = ActiveRecord::Base.connection
    name = Bouncy::Database.family(connection) == :postgresql ? "PostGIS" : "Renamed"
    connection.stub(:adapter_name, name, &)
  end

  test "a signed SNS message is stored, not refused with 503" do
    Bouncy.configuration.adapter = nil
    Bouncy.configuration.ses.region = "us-east-1"
    Bouncy.configuration.ses.topic_arns = [TOPIC]
    Bouncy.configuration.ses.sns_client = Aws::SNS::Client.new(region: "us-east-1", stub_responses: true)
    stub_request(:get, CERT_URL).to_return(body: CERT.to_pem)
    rename do
      status, = Bouncy::Webhook.new.call("REQUEST_METHOD" => "POST", "rack.input" => StringIO.new(signed_envelope), "CONTENT_TYPE" => "text/plain")
      assert_equal 200, status
    end
    assert Bouncy.blocked?("ada@example.com")
    assert Bouncy.blocked?("ben@example.com")
  end

  test "a hold and a sync take their locks" do
    @provider.entries = [entry]
    rename do
      assert_equal :sent, Bouncy.hold("ben@example.com") { :sent }
      Bouncy.sync!
    end
    assert Bouncy.blocked?("ada@example.com")
  end
end
