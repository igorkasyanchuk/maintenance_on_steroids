require_relative "maintenance_on_steroids/version"
require_relative "maintenance_on_steroids/engine"
require_relative "maintenance_on_steroids/instrumentation"
require_relative "maintenance_on_steroids/job_registry"
require_relative "maintenance_on_steroids/form_dsl"
require_relative "maintenance_on_steroids/artifact_dsl"
require_relative "maintenance_on_steroids/job_dsl"
require_relative "maintenance_on_steroids/about_dsl"
require_relative "maintenance_on_steroids/callbacks_dsl"
require_relative "maintenance_on_steroids/params_proxy"
require_relative "maintenance_on_steroids/jsonb_artifact"
require_relative "maintenance_on_steroids/text_artifact"
require_relative "maintenance_on_steroids/csv_artifact"
require_relative "maintenance_on_steroids/artifacts_proxy"
require_relative "maintenance_on_steroids/task"

module MaintenanceOnSteroids
  # Base controller class for the engine's controllers (resolved at load time).
  # Set this in an initializer, before the engine's controllers are loaded.
  mattr_accessor :parent_controller, default: "ActionController::Base"

  # Maximum allowed size (in bytes) for file inputs uploaded when starting a run.
  # Uploads are read into memory and stored in the artifacts table.
  mattr_accessor :max_upload_size, default: 50 * 1024 * 1024

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
  # Shipped placeholders. Leaving the password at its default is treated as
  # *no* access control -- a dashboard behind "admin"/"secret" is not
  # protected, and counting it as configured would make the most dangerous
  # setup quieter than an unconfigured one.
  DEFAULT_HTTP_BASIC_USER_NAME = "admin"
  DEFAULT_HTTP_BASIC_PASSWORD  = "secret"

  mattr_accessor :http_basic_authentication_enabled, default: false
  mattr_accessor :http_basic_authentication_user_name, default: DEFAULT_HTTP_BASIC_USER_NAME
  mattr_accessor :http_basic_authentication_password, default: DEFAULT_HTTP_BASIC_PASSWORD

  # Controller-based access verification.
  # Receives the controller instance. Return true to allow, false to deny.
  # Runs after HTTP Basic (if enabled). Denial renders 403.
  # Example:
  #   MaintenanceOnSteroids.verify_access_proc = ->(controller) {
  #     controller.current_user&.admin?
  #   }
  mattr_accessor :verify_access_proc, default: nil

  # General-purpose authentication hook (instance_exec'd in controller context).
  # Runs after HTTP Basic and before verify_access_proc. Use for custom auth flows.
  # Example:
  #   MaintenanceOnSteroids.authentication = -> {
  #     authenticate_user!
  #     redirect_to main_app.root_path unless current_user.admin?
  #   }
  mattr_accessor :authentication, default: nil

  # Escape hatch for hosts that gate the dashboard somewhere this gem cannot
  # see (reverse proxy, VPN, Rack middleware). Set it to boot in production
  # without configuring any of the layers above -- an explicit, greppable
  # statement that the exposure is intentional.
  mattr_accessor :allow_insecure_dashboard, default: false

  # Raised at boot when the dashboard would be reachable with no access
  # control in production.
  class InsecureDashboardError < StandardError; end

  # Raised by Run#resume! when the job could not be put on the queue. Narrow
  # on purpose: controllers catch this and show the operator why, while any
  # other exception keeps propagating to the app's error reporting.
  class EnqueueFailed < StandardError; end

  class << self
    def configure
      yield self
    end

    # True when HTTP Basic is on *and* carries a password that actually
    # protects anything. Blank counts as unprotected: the controller compares
    # the supplied password against this value, so an empty one authenticates
    # every request -- the common way to get there is a credentials key that
    # is missing or misspelled and quietly resolves to nil.
    def http_basic_authentication_configured?
      http_basic_authentication_enabled && !http_basic_password_unsafe?
    end

    # The shipped placeholder, or blank -- neither is access control.
    def http_basic_password_unsafe?
      password = http_basic_authentication_password.to_s

      password.empty? || password == DEFAULT_HTTP_BASIC_PASSWORD
    end

    # True when at least one access-control layer is meaningfully configured.
    def access_control_configured?
      return true if authentication || verify_access_proc

      http_basic_authentication_configured?
    end

    # Called from the engine's after_initialize. Raises in production unless
    # the host opted in via allow_insecure_dashboard; warns everywhere else.
    def verify_access_control!(logger: Rails.logger, env: Rails.env)
      if access_control_configured?
        # An authentication hook alone only verifies *who* the user is --
        # without verify_access_proc every authenticated user gets in.
        if authentication && verify_access_proc.nil?
          logger&.warn(
            "[MaintenanceOnSteroids] `authentication` is configured without `verify_access_proc`: " \
            "any authenticated user can access the maintenance dashboard. Set " \
            "MaintenanceOnSteroids.verify_access_proc to restrict access (unless your " \
            "authentication hook already enforces authorization)."
          )
        end
        return
      end

      reason =
        if !http_basic_authentication_enabled
          "no access control is configured"
        elsif http_basic_authentication_password.to_s.empty?
          "HTTP Basic is enabled but its password is blank, which authenticates every request"
        else
          "HTTP Basic is enabled but still uses the shipped default password"
        end

      # Built once and prefixed per branch: deriving the warning by stripping a
      # substring out of the raise message would silently start announcing
      # "Refusing to boot" for boots that were never refused.
      body =
        "#{reason}. Anyone who can reach the mounted dashboard could view every task, read its " \
        "source, and start runs against this database. Set http_basic_authentication_password " \
        "(to something other than blank or the default), authentication, or verify_access_proc " \
        "in config/initializers/maintenance_on_steroids.rb. If the dashboard is already protected " \
        "elsewhere (reverse proxy, VPN, middleware), set " \
        "MaintenanceOnSteroids.allow_insecure_dashboard = true to acknowledge that."

      if env.production? && !allow_insecure_dashboard
        raise InsecureDashboardError, "[MaintenanceOnSteroids] Refusing to boot: #{body}"
      end

      logger&.warn("[MaintenanceOnSteroids] #{body}")
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
