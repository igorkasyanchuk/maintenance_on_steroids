require_relative "maintenance_on_steroids/version"
require_relative "maintenance_on_steroids/engine"
require_relative "maintenance_on_steroids/configuration"
require_relative "maintenance_on_steroids/job_registry"
require_relative "maintenance_on_steroids/form_dsl"
require_relative "maintenance_on_steroids/artifact_dsl"
require_relative "maintenance_on_steroids/job_dsl"
require_relative "maintenance_on_steroids/about_dsl"
require_relative "maintenance_on_steroids/callbacks_dsl"
require_relative "maintenance_on_steroids/params_proxy"
require_relative "maintenance_on_steroids/jsonb_artifact"
require_relative "maintenance_on_steroids/text_artifact"
require_relative "maintenance_on_steroids/artifacts_proxy"
require_relative "maintenance_on_steroids/task"

module MaintenanceOnSteroids
  mattr_accessor :parent_controller, default: "ActionController::Base"
  mattr_accessor :tasks_module, default: nil

  # Proc to resolve the current user who triggered the run.
  # Must return an object responding to #id (and optionally #email).
  # Example:
  #   MaintenanceOnSteroids.current_user_resolver = -> { Current.user }
  mattr_accessor :current_user_resolver, default: nil

  # Proc to format user display in the UI.
  # Receives the Run record and returns a string.
  # Default shows email if present, otherwise "Type#ID".
  # Examples:
  #   MaintenanceOnSteroids.user_display_formatter = ->(run) { run.user_email }
  #   MaintenanceOnSteroids.user_display_formatter = ->(run) {
  #     User.find(run.user_id).full_name rescue run.user_email
  #   }
  mattr_accessor :user_display_formatter, default: nil

  # --- Authentication / Authorization ---

  # HTTP Basic Authentication.
  # When enabled, users must provide credentials before any other checks run.
  # Example:
  #   MaintenanceOnSteroids.http_basic_authentication_enabled   = true
  #   MaintenanceOnSteroids.http_basic_authentication_user_name = "admin"
  #   MaintenanceOnSteroids.http_basic_authentication_password  = Rails.application.credentials.maintenance_password
  mattr_accessor :http_basic_authentication_enabled, default: false
  mattr_accessor :http_basic_authentication_user_name, default: "admin"
  mattr_accessor :http_basic_authentication_password, default: "secret"

  # Controller-based access verification.
  # Receives the controller instance. Return true to allow, false to deny.
  # Runs after HTTP Basic (if enabled). Denial renders 403.
  # Example:
  #   MaintenanceOnSteroids.verify_access_proc = ->(controller) {
  #     controller.current_user&.admin?
  #   }
  mattr_accessor :verify_access_proc, default: nil

  # General-purpose authentication hook (instance_exec'd in controller context).
  # Runs after HTTP Basic and verify_access_proc. Use for custom auth flows.
  # Example:
  #   MaintenanceOnSteroids.authentication = -> {
  #     authenticate_user!
  #     redirect_to main_app.root_path unless current_user.admin?
  #   }
  mattr_accessor :authentication, default: nil

  class << self
    def configure
      yield self
    end

    # Discover all task classes defined in the host app
    def task_classes
      load_all_tasks!
      JobRegistry.tasks
    end

    def load_all_tasks!
      JobRegistry.load_all!
    end
  end
end
