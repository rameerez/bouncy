# frozen_string_literal: true

require "test_helper"
require "rake"

class InstallationTest < BouncyTest
  test "generator writes only the adaptive migration and initializer" do
    Dir.mktmpdir("bouncy-install") do |directory|
      capture_io { Bouncy::Generators::InstallGenerator.start([], destination_root: directory) }
      files = Dir["#{directory}/**/*"].select { |path| File.file?(path) }
      assert_equal 2, files.size
      migration = File.read(files.find { |path| path.include?("/migrate/") })
      assert_includes migration, "ActiveRecord::Migration[#{ActiveRecord::VERSION::MAJOR}.#{ActiveRecord::VERSION::MINOR}]"
      assert_includes migration, "primary_key_type, = primary_and_foreign_key_types"
      assert_includes migration, "t.public_send(json_column_type, :provider_entries"
      refute_includes migration, ":payload"
      initializer = File.read("#{directory}/config/initializers/bouncy.rb")
      assert_includes initializer, "config.interception = :log"
      assert_includes initializer, "config.ses.all_sending_paths_listed = false"
      refute(files.any? { |path| path.match?(/madmin|user\.rb|recurring\.yml/) })
    end
  end

  test "generator respects host UUID primary keys" do
    options = Rails.application.config.generators.options[:active_record]
    previous = options[:primary_key_type]
    options[:primary_key_type] = :uuid
    Dir.mktmpdir("bouncy-uuid") do |directory|
      capture_io { Bouncy::Generators::InstallGenerator.start([], destination_root: directory) }
      source = File.read(Dir["#{directory}/db/migrate/*.rb"].sole)
      source = source.gsub("CreateBouncyTables", "CreateBouncyUuidTables").gsub("bouncy_", "bouncy_uuid_")
      path = "#{directory}/uuid_migration.rb"
      File.write(path, source)
      load path
      CreateBouncyUuidTables.migrate(:up)
      connection = ActiveRecord::Base.connection
      type = connection.columns(:bouncy_uuid_suppressions).find { |column| column.name == "id" }.type
      assert_equal(connection.adapter_name == "PostgreSQL" ? :uuid : :string, type)
      model = Class.new(Bouncy::Suppression) { self.table_name = "bouncy_uuid_suppressions" }
      row = model.create!(scope: Bouncy.scope, email: "uuid@example.com", provider: "ses")
      assert_match(/\A[0-9a-f-]{36}\z/, row.id)
      assert_equal [], row.reload.provider_entries
      assert_equal({}, row.details)
      CreateBouncyUuidTables.migrate(:down)
      refute connection.table_exists?(:bouncy_uuid_suppressions)
    end
  ensure
    options[:primary_key_type] = previous
  end

  test "migration selects native JSON storage and independent application defaults" do
    connection = ActiveRecord::Base.connection
    columns = connection.columns(:bouncy_suppressions).index_by(&:name)
    assert_equal(connection.adapter_name == "PostgreSQL" ? :jsonb : :json, columns.fetch("details").type)
    assert_equal false, columns.fetch("details").null
    a = Bouncy::Suppression.new
    b = Bouncy::Suppression.new
    a.details["only_a"] = true
    a.provider_entries << { "only_a" => true }
    assert_equal({}, b.details)
    assert_equal [], b.provider_entries
    Bouncy.block!("json@example.com", note: "Defaults persist")
    row = Bouncy::Suppression.find_by!(email: "json@example.com")
    assert_equal({}, row.details)
    assert_equal [], row.provider_entries
  end

  test "rerunning install keeps the hosts configured initializer" do
    Dir.mktmpdir("bouncy-repeat") do |directory|
      capture_io { Bouncy::Generators::InstallGenerator.start([], destination_root: directory) }
      initializer = "#{directory}/config/initializers/bouncy.rb"
      File.write(initializer, "# Host configuration\n")
      capture_io { Bouncy::Generators::InstallGenerator.start(["--skip"], destination_root: directory) }
      assert_equal "# Host configuration\n", File.read(initializer)
    end
  end

  test "package allowlist includes runtime files and excludes private development material" do
    specification = Gem::Specification.load(File.expand_path("../bouncy.gemspec", __dir__))
    assert_includes specification.files, "lib/bouncy.rb"
    assert_includes specification.files, "lib/generators/bouncy/templates/create_bouncy_tables.rb.erb"
    assert_includes specification.files, "guides/amazon-ses.md"
    refute(specification.files.any? { |path| path.match?(%r{\A(?:docs|test|\.cursor|\.github)/}) })
    refute(specification.dependencies.any? { |dependency| dependency.name.match?(/madmin|aws-sdk/) })
  end

  test "mounted engine reaches the bounded receiver" do
    Bouncy.configuration.adapter = nil
    response = Rack::MockRequest.new(Bouncy::Engine).post("/webhooks/ses", input: "{")
    assert_equal 400, response.status
  end

  test "setup and doctor tasks invoke diagnostic reads and reject APPLY" do
    Rails.application.load_tasks
    @provider.define_singleton_method(:doctor) { { "policy_verified" => true } }
    output, = capture_io { Rake::Task["bouncy:ses:setup"].invoke }
    assert_includes output, "Deploy POST"
    previous = ENV.fetch("APPLY", nil)
    ENV["APPLY"] = "1"
    Rake::Task["bouncy:ses:setup"].reenable
    assert_raises(Bouncy::ConfigurationError) { Rake::Task["bouncy:ses:setup"].invoke }
    capture_io { Rake::Task["bouncy:doctor"].invoke }
    capture_io { Rake::Task["bouncy:sync"].invoke }
    assert Bouncy.last_sync
  ensure
    ENV["APPLY"] = previous
  end
end
