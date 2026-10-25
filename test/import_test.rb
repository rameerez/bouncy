# frozen_string_literal: true

require "test_helper"

class ImportMailer < ActionMailer::Base
  def notice(to)
    mail(from: "sender@example.com", to: to, subject: "Notice", body: "Hello")
  end
end

# Bouncy.import!: a block that another system recorded, carried with its reason and its time.
class ImportTest < BouncyTest
  def setup
    super
    ActionMailer::Base.deliveries.clear
  end

  def hooks
    calls = []
    %i[after_event after_block after_release].each do |hook|
      Bouncy.configuration.public_send("#{hook}=", ->(event) { calls << [hook, event.kind] })
    end
    Bouncy.configuration.on_notification = ->(_notification) { calls << [:on_notification] }
    calls
  end

  test "an import records the reason, the time and an imported event" do
    at = Time.utc(2026, 3, 1, 12, 30, 15.123456r)
    row = Bouncy.import!(" Ada@Example.com ", reason: :hard_bounce, at: at, note: "Carried", actor: "carry-task")

    status = Bouncy.status("ada@example.com")
    assert status.blocked?
    assert_equal :hard_bounce, status.reason
    assert_equal at, status.blocked_at
    assert_equal [at, "hard_bounce", "Ada@Example.com"], [row.event_blocked_at, row.event_reason, row.details["exact_email"]]
    event = Bouncy.events.sole
    assert_equal %w[imported import], [event.kind, event.source]
    assert_equal at, event.occurred_at
    assert_equal({ "reason" => "hard_bounce", "note" => "Carried", "actor" => "carry-task",
                   "ignored_for_policy" => false, "became_blocked" => true }, event.details)
  end

  test "an import dated a year ago blocks and drops mail, and a webhook bounce dated a year ago does not" do
    Bouncy.configuration.interception = :drop
    Bouncy.configuration.require_fresh_sync = false
    assert_equal :accepted, observe("old-webhook@example.com", time: 1.year.ago)
    refute Bouncy.blocked?("old-webhook@example.com")
    assert Bouncy.events.where(kind: "hard_bounce").sole.details["ignored_for_policy"]

    Bouncy.import!("old-import@example.com", reason: :hard_bounce, at: 1.year.ago)
    Bouncy.import!("old-complaint@example.com", reason: :complaint, at: 2.years.ago)
    Bouncy.import!("old-hold@example.com", reason: :manual, at: 3.years.ago, note: "Old support hold")
    %w[old-import old-complaint old-hold].each { |name| assert Bouncy.blocked?("#{name}@example.com"), name }

    %w[old-webhook old-import old-complaint old-hold].each { |name| ImportMailer.notice("#{name}@example.com").deliver_now }
    assert_equal [["old-webhook@example.com"]], ActionMailer::Base.deliveries.map(&:smtp_envelope_to)
  end

  test "an imported bounce follows the sync rule of webhook evidence, and an imported hold does not" do
    Bouncy.configuration.interception = :drop
    Bouncy.import!("bounce@example.com", reason: :hard_bounce, at: 1.year.ago)
    Bouncy.import!("hold@example.com", reason: :manual, at: 1.year.ago)

    ImportMailer.notice("bounce@example.com").deliver_now
    ImportMailer.notice("hold@example.com").deliver_now
    assert_equal [["bounce@example.com"]], ActionMailer::Base.deliveries.map(&:smtp_envelope_to), "no fresh sync yet"

    Bouncy.sync!
    assert Bouncy.sync_fresh?
    ImportMailer.notice("bounce@example.com").deliver_now
    assert_equal 1, ActionMailer::Base.deliveries.size, "a fresh sync enforces the imported bounce"
  end

  test "an import calls no hook and no on_notification" do
    calls = hooks
    Bouncy.import!("ada@example.com", reason: :complaint, at: 1.day.ago)
    Bouncy.import!("ben@example.com", reason: :manual, at: 1.day.ago)
    assert_empty calls

    Bouncy.block!("cleo@example.com", note: "Hold")
    assert_equal [[:after_event, "manual_block"], [:after_block, "manual_block"]], calls
  end

  test "the same import again writes nothing" do
    at = 40.days.ago
    first = Bouncy.import!("ada@example.com", reason: :hard_bounce, at: at, note: "Carried")
    travel 1.minute
    again = Bouncy.import!("ADA@example.com", reason: "hard_bounce", at: at.in_time_zone("Tokyo"), note: "Carried again")

    assert_equal 1, Bouncy::Suppression.count
    assert_equal 1, Bouncy.events.count
    reloaded = Bouncy::Suppression.sole
    assert_equal [first.lock_version, first.updated_at], [reloaded.lock_version, reloaded.updated_at]
    assert_equal reloaded.lock_version, again.lock_version
  end

  test "an import that the row already holds writes nothing, even with its event pruned" do
    at = 10.days.ago
    Bouncy.import!("ada@example.com", reason: :manual, at: at)
    Bouncy.events.delete_all
    version = Bouncy::Suppression.sole.lock_version
    Bouncy.import!("ada@example.com", reason: :manual, at: at + 1.day)
    Bouncy.import!("ada@example.com", reason: :manual, at: at)
    assert_empty Bouncy.events
    assert_equal version, Bouncy::Suppression.sole.lock_version
  end

  test "an import never weakens a stronger block in force" do
    observe("ada@example.com", kind: "complaint", time: 1.hour.ago, details: { "certainty" => "confirmed" })
    Bouncy.import!("ada@example.com", reason: :hard_bounce, at: 1.minute.ago)
    row = Bouncy::Suppression.sole
    assert_equal ["complaint", :complaint], [row.event_reason, Bouncy.status("ada@example.com").reason]
    assert_in_delta 1.minute.ago, row.event_blocked_at, 1, "the newest evidence time"

    observe("ben@example.com", time: 1.hour.ago)
    Bouncy.import!("ben@example.com", reason: :complaint, at: 1.year.ago)
    assert_equal :complaint, Bouncy.status("ben@example.com").reason, "a complaint outranks a hard bounce"
    assert_in_delta 1.hour.ago, Bouncy::Suppression.find_by(email: "ben@example.com").event_blocked_at, 1

    Bouncy.block!("cleo@example.com", note: "Support note")
    Bouncy.import!("cleo@example.com", reason: :manual, at: 1.year.ago, note: "Imported note")
    row = Bouncy::Suppression.find_by(email: "cleo@example.com")
    assert_equal "Support note", row.manual_note
    assert_in_delta 1.year.ago, row.manual_blocked_at, 1

    @provider.entries = [entry("dan@example.com", reason: :complaint)]
    Bouncy.sync!
    Bouncy.import!("dan@example.com", reason: :manual, at: 1.day.ago)
    assert_equal %i[manual complaint], Bouncy.status("dan@example.com").reasons
  end

  test "a release at or after the time of an import fences it" do
    at = 30.days.ago
    Bouncy.import!("ada@example.com", reason: :hard_bounce, at: at)
    Bouncy.release!("ada@example.com", note: "Verified recovery")
    Bouncy.import!("ada@example.com", reason: :hard_bounce, at: at)
    assert_equal 1, Bouncy.events.where(kind: "imported").count, "the repeat is a duplicate"

    Bouncy.import!("ada@example.com", reason: :complaint, at: at)
    refute Bouncy.blocked?("ada@example.com")
    fenced = Bouncy.events.where(kind: "imported").detect { |event| event.details["reason"] == "complaint" }
    assert fenced.details["ignored_for_policy"], "both events occurred at the same time, so the id cannot order them"

    Bouncy.import!("ben@example.com", reason: :manual, at: at)
    Bouncy.release!("ben@example.com", at: :local)
    Bouncy.import!("ben@example.com", reason: :manual, at: at + 1.day)
    refute Bouncy.blocked?("ben@example.com")

    travel 1.second
    Bouncy.import!("ben@example.com", reason: :manual, at: Time.current)
    assert Bouncy.blocked?("ben@example.com"), "a block newer than the release applies"
  end

  test "a sync that no longer finds an imported bounce clears it, as it clears webhook evidence" do
    at = 1.year.ago
    Bouncy.import!("ada@example.com", reason: :hard_bounce, at: at)
    Bouncy.sync!
    assert Bouncy.blocked?("ada@example.com"), "one absent check does not clear webhook evidence"
    Bouncy.sync!
    refute Bouncy.blocked?("ada@example.com")
    assert_equal ["ada@example.com"], @provider.lookups.uniq
    Bouncy.import!("ada@example.com", reason: :complaint, at: at - 1.day)
    refute Bouncy.blocked?("ada@example.com"), "the sync fenced the older evidence"
  end

  test "an import onto a block in force keeps the earliest start" do
    observe("ada@example.com", time: 1.minute.ago)
    started = Bouncy.status("ada@example.com").blocked_at
    Bouncy.import!("ada@example.com", reason: :hard_bounce, at: 1.year.ago)
    assert_in_delta 1.year.ago, Bouncy.status("ada@example.com").blocked_at, 1
    Bouncy.import!("ben@example.com", reason: :manual, at: 1.year.ago)
    Bouncy.import!("ben@example.com", reason: :complaint, at: 1.day.ago)
    assert_in_delta 1.year.ago, Bouncy.status("ben@example.com").blocked_at, 1
    assert_operator started, :>, 1.hour.ago
  end

  test "an import refuses an unknown reason, a time that is not a Time, a future time and an invalid address" do
    assert_raises(ArgumentError) { Bouncy.import!("ada@example.com", reason: :soft_bounces, at: 1.day.ago) }
    assert_raises(ArgumentError) { Bouncy.import!("ada@example.com", reason: :provider_list, at: 1.day.ago) }
    assert_raises(ArgumentError) { Bouncy.import!("ada@example.com", reason: :manual, at: nil) }
    assert_raises(ArgumentError) { Bouncy.import!("ada@example.com", reason: :manual, at: "2026-01-01") }
    assert_raises(ArgumentError) { Bouncy.import!("ada@example.com", reason: :manual, at: 1.hour.from_now) }
    assert_raises(Bouncy::InvalidAddress) { Bouncy.import!("not an address", reason: :manual, at: 1.day.ago) }
    assert_empty Bouncy::Suppression.all

    Bouncy.import!("ada@example.com", reason: :manual, at: 1.day.ago.to_datetime)
    assert Bouncy.blocked?("ada@example.com")

    Bouncy.configuration.scope = nil
    assert_raises(Bouncy::ConfigurationError) { Bouncy.import!("ben@example.com", reason: :manual, at: 1.day.ago) }
  end

  test "the Ingestor call shape of 0.2.0 still records a recent block" do
    observation = Bouncy::Observation.new(
      email: "ada@example.com", kind: "hard_bounce", provider_event_id: "old_suppressions", message_id: nil,
      occurred_at: 1.day.ago, provider_reason: nil, status_code: nil, diagnostic: nil,
      details: { "exact_email" => "ada@example.com", "carried_from" => "old_suppressions", "certainty" => "confirmed" }
    )
    assert_equal :accepted, Bouncy::Ingestor.new.call(observation)
    assert_equal :duplicate, Bouncy::Ingestor.new.call(observation)
    assert Bouncy.blocked?("ada@example.com")
  end
end

# Imports from independent connections and in separate scopes.
class ImportIsolationTest < BouncyTest
  # The importer of these tests counts the imports inside its critical section at once, and asks
  # another connection whether the address lock is free there. The first import waits inside:
  # under the lock no other import of the address can enter.
  def counting_importer(seen)
    test = self
    Class.new(Bouncy::Importer) do
      define_method(:record) do |row, *arguments, **options|
        seen[:guard].synchronize { seen[:most] = [seen[:most], seen[:inside] += 1].max }
        seen[:guard].synchronize { seen[:locked] << test.address_locked?(row.email) }
        sleep 0.3
        super(row, *arguments, **options)
      ensure
        seen[:guard].synchronize { seen[:inside] -= 1 }
      end
      private :record
    end
  end

  # Tries the shared side of the address lock on another connection, without waiting.
  def address_locked?(email)
    Thread.new do
      Bouncy::Record.connection_pool.with_connection do |connection|
        case connection.adapter_name
        when "PostgreSQL"
          key = Bouncy::AddressLock.advisory_key(email)
          free = connection.select_value("SELECT pg_try_advisory_lock_shared(#{key})")
          connection.select_value("SELECT pg_advisory_unlock_shared(#{key})") if free
          !free
        when /Mysql|Trilogy/i
          name = Digest::SHA256.hexdigest("bouncy:address:#{connection.pool.db_config.database}:#{Bouncy.scope}:#{email}")
          connection.uncached { connection.select_value("SELECT IS_FREE_LOCK(#{connection.quote(name)})") }.to_i.zero?
        else
          File.open(Bouncy::AddressLock.lock_path(connection), File::RDWR | File::CREAT) { |file| file.flock(File::LOCK_SH | File::LOCK_NB) == false }
        end
      end
    end.value
  end

  # PostgreSQL and MySQL already give each thread its own connection. In-memory SQLite exists on
  # one connection only, so the models get a file database of their own.
  def with_independent_connections
    return yield unless ActiveRecord::Base.connection.adapter_name == "SQLite"

    Dir.mktmpdir("bouncy-import") do |directory|
      Bouncy::Record.establish_connection(adapter: "sqlite3", database: File.join(directory, "bouncy.sqlite3"), pool: 5, timeout: 10_000)
      CreateBouncyTables.new.exec_migration(Bouncy::Record.connection, :up)
      assert_not_same ActiveRecord::Base.connection, Bouncy::Record.connection
      yield
    ensure
      Bouncy::Record.remove_connection
    end
  end

  # The address has a row already, as after any earlier event, so no unique index orders the
  # imports: only the address lock does.
  test "simultaneous imports of one address on independent connections write one suppression and one event" do
    with_independent_connections do
      observe("ada@example.com", kind: "soft_bounce")
      seen = { guard: Mutex.new, inside: 0, most: 0, locked: [] }
      at = 1.year.ago
      ready = Queue.new
      go = Queue.new
      importer = counting_importer(seen).new
      Bouncy::Importer.stub(:new, -> { importer }) do
        workers = 2.times.map do
          Thread.new do
            Bouncy::Record.connection_pool.with_connection do
              ready << true
              go.pop
              Bouncy.import!("ada@example.com", reason: :hard_bounce, at: at)
              :imported
            end
          rescue StandardError => e
            e
          end
        end
        2.times { ready.pop }
        2.times { go << true }
        assert_equal %i[imported imported], workers.map(&:value)
      end
      assert_equal [true], seen[:locked], "the import holds the address lock, and only one import gets inside"
      assert_equal 1, seen[:most]
      assert_equal 1, Bouncy::Suppression.count
      assert_equal 1, Bouncy.events.where(kind: "imported").count
      assert_equal :hard_bounce, Bouncy.status("ada@example.com").reason
    end
  end

  test "the same address, reason and time in two scopes are two independent blocks" do
    at = 1.year.ago
    other = "ses:210987654321:eu-west-1:account"
    Bouncy.import!("ada@example.com", reason: :complaint, at: at)
    Bouncy.configuration.scope = other
    Bouncy.import!("ada@example.com", reason: :complaint, at: at)

    assert_equal 2, Bouncy::Suppression.where(email: "ada@example.com").count
    assert_equal 2, Bouncy::Event.where(kind: "imported").distinct.count(:dedupe_key)
    assert Bouncy.blocked?("ada@example.com")
    Bouncy.forget!("ada@example.com")
    refute Bouncy.blocked?("ada@example.com")

    Bouncy.configuration.scope = "ses:123456789012:us-east-1:account"
    assert_equal [:complaint, at.floor(6)], [Bouncy.status("ada@example.com").reason, Bouncy.status("ada@example.com").blocked_at]
    assert_equal 1, Bouncy.events.where(kind: "imported").count
  end
end

# Status#blocked_at: the time the block in force began.
class StatusBlockedAtTest < BouncyTest
  test "blocked_at is the time the address became blocked, and nil when it is not blocked" do
    assert_nil Bouncy.status("ada@example.com").blocked_at
    travel_to(Time.utc(2026, 5, 1, 9)) { Bouncy.block!("ada@example.com", note: "Hold") }
    travel_to(Time.utc(2026, 5, 2, 9)) { observe("ada@example.com", time: 1.minute.ago) }
    assert_equal Time.utc(2026, 5, 1, 9), Bouncy.status("ada@example.com").blocked_at
    assert_equal Time.utc(2026, 5, 1, 9), Bouncy.statuses(["ada@example.com"])["ada@example.com"].blocked_at

    Bouncy.release!("ada@example.com", note: "Recovery")
    assert_nil Bouncy.status("ada@example.com").blocked_at
    assert_nil Bouncy.status("ada@example.com").record.blocked_at
  end

  test "blocked_at of a block after an expired soft hold is the start of the new block" do
    Bouncy.configuration.soft_bounce_threshold = 1
    Bouncy.configuration.soft_bounce_block_for = 1.day
    travel_to(Time.utc(2026, 5, 1, 9)) { observe("ada@example.com", kind: "soft_bounce", time: 1.minute.ago) }
    travel_to(Time.utc(2026, 5, 3, 9)) do
      refute Bouncy.blocked?("ada@example.com")
      assert_nil Bouncy.status("ada@example.com").blocked_at, "the soft hold ran out"
      Bouncy.block!("ada@example.com", note: "Hold")
      assert_equal Time.utc(2026, 5, 3, 9), Bouncy.status("ada@example.com").blocked_at
    end
  end
end
