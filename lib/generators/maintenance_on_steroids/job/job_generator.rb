require "rails/generators"

module MaintenanceOnSteroids
  module Generators
    class JobGenerator < Rails::Generators::NamedBase
      source_root File.expand_path("templates", __dir__)

      desc "Creates a new MaintenanceOnSteroids task in app/maintenance/"

      class_option :collection, type: :boolean, default: true, desc: "Generate a collection-based task"

      def create_task_file
        template "job.rb.erb", "app/maintenance/#{file_name}.rb"
      end
    end
  end
end
