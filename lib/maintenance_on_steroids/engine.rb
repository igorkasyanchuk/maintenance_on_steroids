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

    # Invalidate the registry on code reload in development so it never
    # holds stale (unloaded) task class objects.
    config.to_prepare do
      MaintenanceOnSteroids::JobRegistry.reset!
    end

    # Access control is opt-in, so the dangerous configuration is the empty
    # one -- and HTTP Basic left on its shipped password is the same thing
    # wearing a badge. See MaintenanceOnSteroids.verify_access_control!.
    config.after_initialize do
      MaintenanceOnSteroids.verify_access_control!
    end
  end
end
