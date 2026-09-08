# frozen_string_literal: true

require "test_helper"
require "timeout"
require "open3"

if ActiveRecord::Base.connection.adapter_name.match?(/PostgreSQL|Mysql|Trilogy/)
  class ConcurrencyTest < BouncyTest
    test "simultaneous webhook retries commit one event and one state transition" do
      ready = Queue.new
      go = Queue.new
      workers = 4.times.map do
        Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            ready << true
            go.pop
            observe(id: "shared-feedback")
          end
        end
      end
      4.times { ready.pop }
      4.times { go << true }
      workers.each(&:value)
      assert_equal 1, Bouncy.events.count
      assert_equal 1, Bouncy.blocked.count
    end

    test "scope lock is held across independent connections" do
      acquired = Queue.new
      release = Queue.new
      first = Thread.new do
        Bouncy::ScopeLock.synchronize do
          acquired << true
          release.pop
        end
      end
      acquired.pop
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        result = connection.select_value(lock_probe(connection))
        assert_includes [false, 0], result
      end
      release << true
      first.value
      Bouncy::ScopeLock.synchronize { assert true }
    ensure
      release << true if first&.alive?
      first&.join
    end

    test "scope lock releases after failure" do
      assert_raises(RuntimeError) { Bouncy::ScopeLock.synchronize { raise "worker failed" } }
      worker = Thread.new { Bouncy::ScopeLock.synchronize { :acquired } }
      assert_equal :acquired, Timeout.timeout(3) { worker.value }
    end

    test "scope lock excludes another process" do
      Bouncy::ScopeLock.synchronize do
        script = <<~RUBY
          require "active_record"
          ActiveRecord::Base.establish_connection(ENV.fetch("DATABASE_URL"))
          result = ActiveRecord::Base.connection.select_value(ARGV.fetch(0))
          exit([false, 0].include?(result) ? 0 : 1)
        RUBY
        _output, status = Open3.capture2e(RbConfig.ruby, "-e", script, lock_probe(ActiveRecord::Base.connection))
        assert status.success?
      end
    end

    private

    def lock_probe(connection)
      if connection.adapter_name == "PostgreSQL"
        key = Digest::SHA256.hexdigest(Bouncy.scope)[0, 15].to_i(16)
        "SELECT pg_try_advisory_lock(#{key})"
      else
        name = Digest::SHA256.hexdigest("bouncy:#{connection.pool.db_config.database}:#{Bouncy.scope}")
        "SELECT GET_LOCK('#{name}', 0)"
      end
    end
  end
end
