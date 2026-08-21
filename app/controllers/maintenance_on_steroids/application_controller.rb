module MaintenanceOnSteroids
  class ApplicationController < MaintenanceOnSteroids.parent_controller.constantize
    protect_from_forgery with: :exception

    layout "maintenance_on_steroids/application"

    before_action :verify_http_basic_authentication
    before_action :run_authentication_hook
    before_action :verify_access

    private

    # Step 1: HTTP Basic auth (if enabled)
    def verify_http_basic_authentication
      return unless MaintenanceOnSteroids.http_basic_authentication_enabled

      # A blank configured password would make secure_compare(supplied, "")
      # succeed for anyone sending an empty password. Refuse outright rather
      # than authenticate against nothing.
      if MaintenanceOnSteroids.http_basic_authentication_password.to_s.empty?
        Rails.logger.error(
          "[MaintenanceOnSteroids] HTTP Basic is enabled but the password is blank; denying access. " \
          "Set MaintenanceOnSteroids.http_basic_authentication_password."
        )
        return render plain: "Access denied", status: :forbidden
      end

      authenticate_or_request_with_http_basic("Maintenance on Steroids") do |username, password|
        ActiveSupport::SecurityUtils.secure_compare(username, MaintenanceOnSteroids.http_basic_authentication_user_name.to_s) &
          ActiveSupport::SecurityUtils.secure_compare(password, MaintenanceOnSteroids.http_basic_authentication_password.to_s)
      end
    end

    # Step 2: General-purpose authentication hook (if configured)
    def run_authentication_hook
      return unless MaintenanceOnSteroids.authentication

      instance_exec(&MaintenanceOnSteroids.authentication)
    end

    # Step 3: Proc-based access check (if configured)
    def verify_access
      return unless MaintenanceOnSteroids.verify_access_proc

      unless MaintenanceOnSteroids.verify_access_proc.call(self)
        render plain: "Access denied", status: :forbidden
      end
    end

    # Resolve the current user in controller context where Devise/Warden methods are available.
    # The resolver proc receives the controller so it can call current_user, etc.
    def resolve_current_user
      resolver = MaintenanceOnSteroids.current_user_resolver
      return nil unless resolver

      if resolver.arity == 0
        resolver.call
      else
        resolver.call(self)
      end
    rescue => e
      Rails.logger.debug "[MaintenanceOnSteroids] Could not resolve current user: #{e.message}"
      nil
    end
  end
end
