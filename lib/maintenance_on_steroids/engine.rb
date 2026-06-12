module MaintenanceOnSteroids
  class Engine < ::Rails::Engine
    isolate_namespace MaintenanceOnSteroids

    initializer "maintenance_on_steroids.autoload_tasks", before: :set_autoload_paths do |app|
      tasks_path = Rails.root.join("app/maintenance")
      if tasks_path.exist?
        app.config.autoload_paths += [tasks_path.to_s]
        app.config.eager_load_paths += [tasks_path.to_s]
      end
    end
  end
end
