# frozen_string_literal: true

require "rails/generators/active_record"

module Bouncy
  module Generators
    class InstallGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration

      source_root File.expand_path("templates", __dir__)

      def self.next_migration_number(dirname)
        ActiveRecord::Generators::Base.next_migration_number(dirname)
      end

      def create_files
        migration_template "create_bouncy_tables.rb.erb", File.join(db_migrate_path, "create_bouncy_tables.rb")
        destination = "config/initializers/bouncy.rb"
        if File.exist?(File.expand_path(destination, destination_root))
          say_status :skip, "#{destination} already exists; keeping your configuration", :yellow
        else
          template "initializer.rb.tt", destination
        end
        say "Run bin/rails db:migrate. Set your account scope, region and allowed SNS topics."
        say "Mount Bouncy::Engine at /bouncy, then follow guides/amazon-ses.md."
        say "Schedule Bouncy::SyncJob hourly and Bouncy::PruneJob daily using your application's scheduler."
        say "Optional model integration: bouncy :email. No model or admin files were changed."
      end

      private

      def migration_version
        "[#{ActiveRecord::VERSION::MAJOR}.#{ActiveRecord::VERSION::MINOR}]"
      end
    end
  end
end
