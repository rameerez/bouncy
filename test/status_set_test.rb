# frozen_string_literal: true

require "test_helper"

class StatusSetTest < BouncyTest
  test "answers many addresses with one query, in any spelling" do
    Bouncy.block!("ada@example.com", note: "Hold")
    observe("ben@example.com")
    queries = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      queries << payload[:sql] if payload[:sql].include?("bouncy_suppressions") && payload[:name] != "SCHEMA"
    end
    statuses = Bouncy.statuses([" Ada@Example.com ", "ben@example.com", "carol@example.com", "not an address", nil])
    assert_equal 1, queries.size, queries.inspect
    assert statuses["ADA@example.com"].blocked?
    assert_equal :manual, statuses["ada@example.com"].reason
    assert_equal :hard_bounce, statuses["ben@example.com"].reason
    assert_equal :no_known_block, statuses["carol@example.com"].knowledge
    assert_equal :no_known_block, statuses["never-asked@example.com"].knowledge
    refute statuses["not an address"].blocked?
    assert_equal 3, statuses.size
    assert_equal %w[ada@example.com ben@example.com], statuses.blocked.map(&:first).sort
    assert_equal "ada@example.com", statuses["ada@example.com"].record.email
    assert_equal statuses["ada@example.com"].record, Bouncy::Suppression.find_by(email: "ada@example.com")
    assert_nil statuses["carol@example.com"].record
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  test "reports unconfigured and unavailable knowledge for every lookup" do
    Bouncy.configuration.scope = nil
    statuses = Bouncy.statuses(["ada@example.com"])
    assert_equal :unconfigured, statuses["ada@example.com"].knowledge
    assert_equal 1, statuses.size
    knowledge = statuses.map { |_email, status| status.knowledge }
    assert_equal [:unconfigured], knowledge
    Bouncy.configuration.scope = "ses:123456789012:us-east-1:account"
    Bouncy::Suppression.stub(:where, ->(*) { raise ActiveRecord::ConnectionNotEstablished }) do
      statuses = Bouncy.statuses(["ada@example.com"])
      assert_equal :unavailable, statuses["ada@example.com"].knowledge
      refute statuses["ada@example.com"].blocked?
      assert_equal ["ada@example.com"], statuses.to_h.keys
      knowledge = statuses.map { |_email, status| status.knowledge }
      assert_equal [:unavailable], knowledge
    end
    Bouncy::Suppression.stub(:where, ->(*) { raise ActiveRecord::StatementInvalid, "bad SQL" }) do
      assert_raises(ActiveRecord::StatementInvalid) { Bouncy.statuses(["ada@example.com"]) }
    end
  end

  test "scope isolation applies to batch lookups" do
    Bouncy.block!("ada@example.com", note: "Hold")
    Bouncy.configuration.scope = "ses:999999999999:us-east-1:account"
    refute Bouncy.statuses(["ada@example.com"])["ada@example.com"].blocked?
  end

  test "normalization skips invalid addresses but does not hide programming errors" do
    assert_equal 0, Bouncy.statuses([nil, "not an address"]).size
    broken = Object.new
    def broken.to_s = raise("broken address conversion")

    assert_raises(RuntimeError) { Bouncy.statuses([broken]) }
  end
end
