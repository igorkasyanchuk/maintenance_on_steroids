require "rails/generators"
require "rails/generators/active_record"

module MaintenanceOnSteroids
  module Generators
    class InstallGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration

      source_root File.expand_path("templates", __dir__)

      desc "Creates the migration and initializer for MaintenanceOnSteroids and mounts the engine."

      def create_migration_file
        migration_template(
          "create_maintenance_on_steroids_tables.rb.erb",
          "db/migrate/create_maintenance_on_steroids_tables.rb"
        )
      end

      def create_initializer
        template "initializer.rb", "config/initializers/maintenance_on_steroids.rb"
      end

      def create_maintenance_directory
        empty_directory "app/maintenance"
        create_file "app/maintenance/.keep"
      end

      def mount_engine
        route 'mount MaintenanceOnSteroids::Engine, at: "/maintenance"'
      end

      def show_post_install
        say ""
        say "MaintenanceOnSteroids installed successfully!", :green
        say ""
        say "Next steps:"
        say "  1. Run migrations: rails db:migrate"
        say "  2. Configure access control in config/initializers/maintenance_on_steroids.rb"
        say "  3. Create tasks in app/maintenance/"
        say "  4. Visit /maintenance in your browser"
        say ""
        say "The dashboard is mounted WITHOUT access control until you configure it,", :yellow
        say "and it can start any task against your database. In production the engine", :yellow
        say "refuses to boot until one layer is set (or allow_insecure_dashboard = true).", :yellow
        say ""
      end

      private

      def migration_version
        "[#{ActiveRecord::Migration.current_version}]"
      end
    end
  end
end
