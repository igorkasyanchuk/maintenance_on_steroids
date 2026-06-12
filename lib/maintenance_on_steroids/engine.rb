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

    # An authentication hook alone only verifies *who* the user is -- without
    # verify_access_proc every authenticated user can reach the dashboard.
    config.after_initialize do
      if MaintenanceOnSteroids.authentication && MaintenanceOnSteroids.verify_access_proc.nil?
        Rails.logger.warn(
          "[MaintenanceOnSteroids] `authentication` is configured without `verify_access_proc`: " \
          "any authenticated user can access the maintenance dashboard. Set " \
          "MaintenanceOnSteroids.verify_access_proc to restrict access (unless your " \
          "authentication hook already enforces authorization)."
        )
      end
    end
  end
end
